defmodule Earss.Source.Registry do
  @moduledoc """
  Process-owned registry of source adapters (`Earss.Source.Adapter`).

  Plugins call `register/1` from their application start after `:earss` is up.
  Duplicate ids are rejected.
  """

  use GenServer

  @table :earss_source_registry

  # —— public API ——

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Register an adapter.

  ## Options / map keys

    * `:id` / `"id"` — adapter id (required if not taken from module)
    * `:module` / `"module"` — module implementing `Earss.Source.Adapter`
    * `:version` — optional string
  """
  @spec register(map() | keyword()) :: :ok | {:error, term()}
  def register(spec) when is_list(spec), do: register(Map.new(spec))

  def register(%{} = spec) do
    GenServer.call(__MODULE__, {:register, normalize_spec(spec)})
  end

  @spec fetch(String.t()) :: {:ok, module()} | :error
  def fetch(id) when is_binary(id) do
    case :ets.lookup(@table, id) do
      [{^id, %{module: mod}}] -> {:ok, mod}
      [] -> :error
    end
  end

  def fetch(_), do: :error

  @spec list_adapters() :: [map()]
  def list_adapters do
    :ets.tab2list(@table)
    |> Enum.map(fn {id, meta} -> Map.put(meta, :id, id) end)
    |> Enum.sort_by(& &1.id)
  end

  @spec list_routes() :: [map()]
  def list_routes do
    list_adapters()
    |> Enum.flat_map(fn %{id: id, module: mod} ->
      routes =
        try do
          mod.routes()
        rescue
          _ -> []
        end

      Enum.map(routes, &Map.put(&1, :adapter_id, id))
    end)
  end

  # —— GenServer ——

  @impl true
  def init(_opts) do
    table =
      :ets.new(@table, [
        :named_table,
        :set,
        :protected,
        read_concurrency: true
      ])

    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:register, {:error, _} = err}, _from, state), do: {:reply, err, state}

  def handle_call({:register, {:ok, %{id: id, module: mod} = meta}}, _from, state) do
    cond do
      not is_atom(mod) ->
        {:reply, {:error, :invalid_module}, state}

      not function_exported?(mod, :id, 0) ->
        {:reply, {:error, :not_an_adapter}, state}

      true ->
        api =
          try do
            mod.adapter_api()
          rescue
            _ -> nil
          end

        expected = Earss.Source.Adapter.api_version()

        cond do
          api != expected ->
            {:reply, {:error, {:unsupported_adapter_api, api, expected}}, state}

          :ets.insert_new(@table, {id, Map.drop(meta, [:id])}) ->
            {:reply, :ok, state}

          true ->
            {:reply, {:error, :already_registered}, state}
        end
    end
  end

  defp normalize_spec(spec) do
    id = Map.get(spec, :id) || Map.get(spec, "id")
    mod = Map.get(spec, :module) || Map.get(spec, "module")
    version = Map.get(spec, :version) || Map.get(spec, "version")

    id =
      cond do
        is_binary(id) and id != "" -> id
        is_atom(mod) and function_exported?(mod, :id, 0) -> mod.id()
        true -> nil
      end

    if is_binary(id) and is_atom(mod) do
      {:ok, %{id: id, module: mod, version: version}}
    else
      {:error, :invalid_spec}
    end
  end
end
