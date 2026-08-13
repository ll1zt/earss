defmodule Earss.Enrichment.PendingWorker do
  @moduledoc """
  Periodic retry of enrichment-pending entries.

  New entries of translated feeds are flagged `translation_pending_at` at
  ingest and hidden from protocol clients until every target language is
  stored. This worker periodically re-runs
  `Earss.Enrichment.process_pending/1` so a failed/slow provider call
  eventually produces the enrichment instead of leaking the original.
  Orphaned pending flags (feed's translation disabled in the meantime) are
  cleared, making the original visible again.

  Each run executes **asynchronously** under `Earss.Enrichment.TaskSupervisor`
  (`Task.Supervisor.async_nolink/2`): a slow provider call (multi-model
  fallback chains can take minutes) never blocks the GenServer, and ticks
  are skipped while a run is still in flight — the worker keeps its cadence
  instead of piling up overdue ticks.

  Interval: `config :earss, :translate, pending_worker: %{interval_ms: 60_000}`
  (or the flat `:interval_ms` opt; default 60s).
  """

  use GenServer

  alias Earss.Enrichment

  @task_supervisor Earss.Enrichment.TaskSupervisor

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    interval = interval_ms(opts)
    Process.send_after(self(), :tick, interval)
    {:ok, %{interval: interval, running: false, task: nil}}
  end

  @impl true
  def handle_info(:tick, %{running: true} = state) do
    # Previous run still in flight: keep the cadence, do not overlap.
    Process.send_after(self(), :tick, state.interval)
    {:noreply, state}
  end

  def handle_info(:tick, %{running: false} = state) do
    task =
      Task.Supervisor.async_nolink(@task_supervisor, fn ->
        Enrichment.process_pending()
      end)

    Process.send_after(self(), :tick, state.interval)
    {:noreply, %{state | running: true, task: task}}
  end

  def handle_info({ref, _result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, %{state | running: false, task: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{task: %Task{ref: ref}} = state) do
    {:noreply, %{state | running: false, task: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp interval_ms(opts) do
    Keyword.get(opts, :interval_ms) || get_in(opts, [:pending_worker, :interval_ms]) || 60_000
  end
end
