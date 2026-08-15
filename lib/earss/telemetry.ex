defmodule Earss.Telemetry do
  @moduledoc """
  Earss telemetry: event names and emission helpers.

  Events are emitted with `:telemetry.execute/3` (measurements + metadata)
  at the pipeline's key boundaries — feed fetch, poller cycle, enrichment,
  retention — and aggregated by `Earss.Telemetry.Store` for `/admin/metrics`
  (docs/roadmap.md: Observability). With no handler attached, emission is a
  no-op, so these calls are safe on every code path.

  Event shape follows the telemetry convention: measurements are numbers
  (duration in native units), metadata is contextual (feed id, outcome, …).
  """

  @doc "Fetch of a single feed. Measurements: duration, outcome, upserted, skipped."
  def event_feed_fetch, do: [:earss, :feed, :fetch]

  @doc "One poller cycle. Measurements: duration, feeds, ok, failed."
  def event_poller_tick, do: [:earss, :poller, :tick]

  @doc "Translation of newly ingested entries. Measurements: duration, entries, translated."
  def event_enrichment_translate, do: [:earss, :enrichment, :translate]

  @doc "Pending-worker retry cycle. Measurements: duration, processed."
  def event_enrichment_pending, do: [:earss, :enrichment, :pending]

  @doc "Retention run. Measurements: duration, states, entries, feeds."
  def event_retention_run, do: [:earss, :retention, :run]

  @doc """
  Attach the default aggregation handler (`Earss.Telemetry.Store`) to every
  Earss event. No-op when `config :earss, :telemetry, enabled: false`.
  """
  @spec attach_default_handler() :: :ok
  def attach_default_handler do
    if enabled?() do
      Enum.each(all_events(), fn event ->
        :telemetry.attach({__MODULE__, event}, event, &Earss.Telemetry.Store.handle_event/4, %{})
      end)
    end

    :ok
  end

  @doc "All Earss events (in attach order)."
  @spec all_events() :: [[atom()]]
  def all_events do
    [
      event_feed_fetch(),
      event_poller_tick(),
      event_enrichment_translate(),
      event_enrichment_pending(),
      event_retention_run()
    ]
  end

  @doc "Whether the default telemetry store/handler are enabled."
  @spec enabled?() :: boolean()
  def enabled? do
    :earss |> Application.get_env(:telemetry, []) |> Keyword.get(:enabled, true)
  end
end
