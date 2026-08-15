defmodule Earss.Source.Registry do
  @moduledoc """
  Process-owned registry of source adapters (`Earss.Source.Adapter`).

  Thin facade over the generic `Earss.Registry` server: this module owns the
  kind-specific contract (adapter behaviour, `id/0` requirement, `:not_an_adapter`
  error atom) and exposes the same public API plugins have always used. See
  `Earss.Registry` for the generic registration semantics.
  """

  @server Earss.Registry.Source
  @table :earss_source_registry

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end

  def start_link(opts \\ []) do
    Earss.Registry.start_link(registry_opts(opts))
  end

  @doc """
  Register an adapter.

  ## Options / map keys

    * `:id` / `"id"` — adapter id (required if not taken from module `id/0`)
    * `:module` / `"module"` — module implementing `Earss.Source.Adapter`
    * `:version` — optional string
  """
  @spec register(map() | keyword()) :: :ok | {:error, term()}
  def register(spec), do: Earss.Registry.register(@server, spec)

  @spec fetch(String.t()) :: {:ok, module()} | :error
  def fetch(id), do: Earss.Registry.fetch(@table, id)

  @spec list_adapters() :: [map()]
  def list_adapters, do: Earss.Registry.list(@table)

  @doc "List adapter routes across all registered adapters."
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

  defp registry_opts(opts) do
    [
      name: @server,
      table: @table,
      contract: Earss.Source.Adapter,
      required_callbacks: [{:id, 0}],
      not_a_module_error: :not_an_adapter
    ] ++ opts
  end
end
