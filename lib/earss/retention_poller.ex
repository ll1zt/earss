defmodule Earss.RetentionPoller do
  @moduledoc """
  Periodic GenServer that runs `Earss.Retention.run_all/0`.

  Configuration (`config :earss, :retention_poller`):

    * `:enabled` — default `true` outside test
    * `:interval_ms` — default 24 hours
    * `:batch_size` — passed through to retention deletes
    * `:initial_delay_ms` — delay before first run (default 60s)
  """

  use GenServer

  require Logger

  alias Earss.Retention

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Trigger one retention pass immediately (async).
  """
  def run_now do
    GenServer.cast(__MODULE__, :run)
  end

  @impl true
  def init(opts) do
    state = %{
      interval_ms: opt(opts, :interval_ms, 24 * 60 * 60 * 1000),
      batch_size: opt(opts, :batch_size, 1000),
      initial_delay_ms: opt(opts, :initial_delay_ms, 60_000)
    }

    schedule_tick(state.initial_delay_ms)
    {:ok, state}
  end

  @impl true
  def handle_cast(:run, state) do
    do_run(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:tick, state) do
    do_run(state)
    schedule_tick(state.interval_ms)
    {:noreply, state}
  end

  defp do_run(state) do
    Logger.info("RetentionPoller: starting run")
    Retention.run_all(batch_size: state.batch_size)
  rescue
    e ->
      Logger.error("RetentionPoller crashed: #{Exception.message(e)}")
  end

  defp schedule_tick(ms), do: Process.send_after(self(), :tick, ms)

  defp opt(opts, key, default) do
    Keyword.get(opts, key) ||
      Application.get_env(:earss, :retention_poller, []) |> Keyword.get(key, default)
  end
end
