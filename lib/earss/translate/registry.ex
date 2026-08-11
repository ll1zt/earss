defmodule Earss.Translate.Registry do
  @moduledoc """
  Process-owned registry of translation providers (`Earss.Source.Translator`).

  The translation twin of `Earss.Source.Registry`: plugins call `register/1`
  from their application start once `:earss` is up. Duplicate ids are
  rejected, and modules must report the current contract `adapter_api`.
  """

  use GenServer

  @table :earss_translate_registry

  # —— public API ——

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Register a translator.

  ## Options / map keys

    * `:id` / `"id"` — translator id (required if not taken from module)
    * `:module` / `"module"` — module implementing `Earss.Source.Translator`
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

  @spec list_translators() :: [map()]
  def list_translators do
    :ets.tab2list(@table)
    |> Enum.map(fn {id, meta} -> Map.put(meta, :id, id) end)
    |> Enum.sort_by(& &1.id)
  end

  @doc "Remove a translator by id (used by tests and operator tooling)."
  @spec unregister(String.t()) :: :ok
  def unregister(id) when is_binary(id) do
    GenServer.call(__MODULE__, {:unregister, id})
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
  def handle_call({:unregister, id}, _from, state) do
    :ets.delete(@table, id)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:register, {:error, _} = err}, _from, state), do: {:reply, err, state}

  def handle_call({:register, {:ok, %{id: id, module: mod} = meta}}, _from, state) do
    cond do
      not is_atom(mod) ->
        {:reply, {:error, :invalid_module}, state}

      not Code.ensure_loaded?(mod) or not function_exported?(mod, :id, 0) ->
        {:reply, {:error, :not_a_translator}, state}

      true ->
        api =
          try do
            mod.adapter_api()
          rescue
            _ -> nil
          end

        expected = Earss.Source.Translator.api_version()

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
        is_atom(mod) and Code.ensure_loaded?(mod) and function_exported?(mod, :id, 0) -> mod.id()
        true -> nil
      end

    if is_binary(id) and is_atom(mod) do
      {:ok, %{id: id, module: mod, version: version}}
    else
      {:error, :invalid_spec}
    end
  end
end
