defmodule Earss.Translate.PendingWorker do
  @moduledoc """
  Periodic retry of translation-pending entries.

  New entries of translated feeds are flagged `translation_pending_at` at
  ingest and hidden from protocol clients until every target language is
  stored. This worker periodically re-runs `Earss.Translate.process_pending/1`
  so a failed/slow provider call eventually produces the translation instead
  of leaking the original. Orphaned pending flags (feed's translation disabled
  in the meantime) are cleared, making the original visible again.

  Interval: `config :earss, :translate, pending_worker: %{interval_ms: 60_000}`
  (default 60s).
  """

  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval_ms, 60_000)
    Process.send_after(self(), :tick, interval)
    {:ok, %{interval: interval}}
  end

  @impl true
  def handle_info(:tick, state) do
    _ = Earss.Translate.process_pending()
    Process.send_after(self(), :tick, state.interval)
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}
end
