defmodule Earss.TTS.Registry do
  @moduledoc """
  Process-owned registry of TTS providers (`Earss.TTS.Provider`).

  Thin facade over the generic `Earss.Registry` server (same pattern as
  `Earss.Source.Registry`): this module owns the kind-specific contract
  (provider behaviour, `id/0` + `synthesize/2` requirements) and exposes
  the single-argument `register/1` plugins call from their application
  start. See `Earss.Registry` for the generic registration semantics.
  """

  @server Earss.Registry.TTS
  @table :earss_tts_registry

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end

  def start_link(opts \\ []) do
    Earss.Registry.start_link(registry_opts(opts))
  end

  @doc """
  Register a provider.

  ## Options / map keys

    * `:id` / `"id"` — provider id (required if not taken from module `id/0`)
    * `:module` / `"module"` — module implementing `Earss.TTS.Provider`
    * `:version` — optional string
  """
  @spec register(map() | keyword()) :: :ok | {:error, term()}
  def register(spec), do: Earss.Registry.register(@server, spec)

  @spec fetch(String.t()) :: {:ok, module()} | :error
  def fetch(id), do: Earss.Registry.fetch(@table, id)

  @spec list_providers() :: [map()]
  def list_providers, do: Earss.Registry.list(@table)

  @doc "Remove a provider by id (used by tests and operator tooling)."
  @spec unregister(String.t()) :: :ok
  def unregister(id), do: Earss.Registry.unregister(@server, id)

  defp registry_opts(opts) do
    [
      name: @server,
      table: @table,
      contract: Earss.TTS.Provider,
      required_callbacks: [{:id, 0}, {:synthesize, 2}],
      not_a_module_error: :not_a_provider
    ] ++ opts
  end
end
