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
  Run `fun`, then emit `event` with `measurements` merged with `duration`
  (monotonic, native units) and `metadata`. Returns `fun`'s result unchanged.
  """
  @spec timed([atom()], map(), map(), (-> term())) :: term()
  def timed(event, measurements, metadata, fun) do
    start = System.monotonic_time()
    result = fun.()

    :telemetry.execute(
      event,
      Map.put(measurements, :duration, System.monotonic_time() - start),
      metadata
    )

    result
  end
end
