defmodule Earss.Enrichment.Registry do
  @moduledoc """
  Process-owned registry of content enrichment providers
  (`Earss.Source.Enricher` — translation, TTS, …).

  Thin facade over the generic `Earss.Registry` server: this module owns the
  kind-specific contract (enricher behaviour, `enrich/2` requirement,
  `:not_an_enricher` error atom) and exposes the same public API plugins have
  always used. See `Earss.Registry` for the generic registration semantics.
  """

  @server Earss.Registry.Enrichment
  @table :earss_enrichment_registry

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end

  def start_link(opts \\ []) do
    Earss.Registry.start_link(registry_opts(opts))
  end

  @doc """
  Register an enricher.

  ## Options / map keys

    * `:id` / `"id"` — enricher id (required if not taken from module `id/0`)
    * `:module` / `"module"` — module implementing `Earss.Source.Enricher`
    * `:version` — optional string
  """
  @spec register(map() | keyword()) :: :ok | {:error, term()}
  def register(spec), do: Earss.Registry.register(@server, spec)

  @spec fetch(String.t()) :: {:ok, module()} | :error
  def fetch(id), do: Earss.Registry.fetch(@table, id)

  @spec list_enrichers() :: [map()]
  def list_enrichers, do: Earss.Registry.list(@table)

  @doc "Remove an enricher by id (used by tests and operator tooling)."
  @spec unregister(String.t()) :: :ok
  def unregister(id), do: Earss.Registry.unregister(@server, id)

  defp registry_opts(opts) do
    [
      name: @server,
      table: @table,
      contract: Earss.Source.Enricher,
      required_callbacks: [{:enrich, 2}],
      not_a_module_error: :not_an_enricher
    ] ++ opts
  end
end
