defmodule Earss.Registry do
  @moduledoc """
  Generic process-owned plugin registry backed by ETS.

  Each plugin kind (source adapters, enrichment providers, TTS providers) is a
  thin facade module over one instance of this server. The facade supplies the
  kind-specific contract at `start_link/1`:

    * `:name` — registered process name (one per kind)
    * `:table` — ETS table name (unique per kind)
    * `:contract` — behaviour module exposing `api_version/0` (e.g.
      `Earss.Source.Adapter`)
    * `:required_callbacks` — `[{name, arity}]` the plugin module must export
      to be accepted (e.g. `[{:enrich, 2}]`)
    * `:not_a_module_error` — error atom for a module that fails validation
      (e.g. `:not_an_adapter`); kept per kind so existing callers and tests
      see unchanged atoms

  Plugins call `register/1` from their application start once `:earss` is up.
  Duplicate ids are rejected, and modules must report the current contract
  `adapter_api` and implement the required callbacks.

  Registration state lives in the GenServer; hot-path lookups (`fetch/2`,
  `list/2`) read the ETS table directly without a GenServer call.

  Facades today: `Earss.Source.Registry`, `Earss.Enrichment.Registry`
  (`Earss.TTS.Registry` joins once the TTS branch lands).
  """

  use GenServer

  ## Public API — facades pass their server / table

  @doc """
  Start a registry instance. `opts`:

    * `:name` — required, registered process name
    * `:table` — required, ETS table name
    * `:contract` — required, module with `api_version/0`
    * `:required_callbacks` — default `[]`
    * `:not_a_module_error` — default `:invalid_module`
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Register a plugin.

  ## Options / map keys

    * `:id` / `"id"` — plugin id (required if not taken from module `id/0`)
    * `:module` / `"module"` — plugin module
    * `:version` — optional string
  """
  @spec register(GenServer.server(), map() | keyword()) :: :ok | {:error, term()}
  def register(server, spec) when is_list(spec), do: register(server, Map.new(spec))

  def register(server, %{} = spec) do
    GenServer.call(server, {:register, spec})
  end

  @doc "Remove a plugin by id (used by tests and operator tooling)."
  @spec unregister(GenServer.server(), String.t()) :: :ok
  def unregister(server, id) when is_binary(id) do
    GenServer.call(server, {:unregister, id})
  end

  @doc "Look up a plugin module by id (direct ETS read, no GenServer call)."
  @spec fetch(atom(), String.t()) :: {:ok, module()} | :error
  def fetch(table, id) when is_binary(id) do
    case :ets.lookup(table, id) do
      [{^id, %{module: mod}}] -> {:ok, mod}
      [] -> :error
    end
  end

  def fetch(_table, _id), do: :error

  @doc "List registered plugins, sorted by id (direct ETS read)."
  @spec list(atom()) :: [map()]
  def list(table) do
    :ets.tab2list(table)
    |> Enum.map(fn {id, meta} -> Map.put(meta, :id, id) end)
    |> Enum.sort_by(& &1.id)
  end

  ## Validation — pure, shared by the GenServer and tests

  @doc """
  Normalize and validate a registration spec against the registry's contract.

  Returns `{:ok, %{id: id, module: mod, version: version}}` or an error tuple
  with the atoms the per-kind registries have always used
  (`:invalid_spec`, the kind's `:not_a_*` error,
  `{:unsupported_adapter_api, api, expected}`, `:already_registered`).
  """
  @spec validate(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def validate(spec, opts) when is_map(spec) do
    contract = Keyword.fetch!(opts, :contract)
    required = Keyword.get(opts, :required_callbacks, [])
    not_a = Keyword.get(opts, :not_a_module_error, :invalid_module)

    with {:ok, %{module: mod} = meta} <- normalize_spec(spec),
         :ok <- validate_module(mod, required, not_a),
         :ok <- validate_api(mod, contract) do
      {:ok, meta}
    end
  end

  ## GenServer

  @impl true
  def init(opts) do
    table = Keyword.fetch!(opts, :table)

    :ets.new(table, [
      :named_table,
      :set,
      :protected,
      read_concurrency: true
    ])

    {:ok, %{table: table, opts: opts}}
  end

  @impl true
  def handle_call({:register, spec}, _from, state) do
    case validate(spec, state.opts) do
      {:ok, %{id: id} = meta} ->
        if :ets.insert_new(state.table, {id, Map.drop(meta, [:id])}) do
          {:reply, :ok, state}
        else
          {:reply, {:error, :already_registered}, state}
        end

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  @impl true
  def handle_call({:unregister, id}, _from, state) do
    :ets.delete(state.table, id)
    {:reply, :ok, state}
  end

  ## Internal

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

  defp validate_module(mod, required, not_a) do
    if is_atom(mod) and Code.ensure_loaded?(mod) and
         Enum.all?(required, fn {f, a} -> function_exported?(mod, f, a) end) do
      :ok
    else
      {:error, not_a}
    end
  end

  defp validate_api(mod, contract) do
    api =
      try do
        mod.adapter_api()
      rescue
        _ -> nil
      end

    expected = contract.api_version()

    if api == expected do
      :ok
    else
      {:error, {:unsupported_adapter_api, api, expected}}
    end
  end
end
