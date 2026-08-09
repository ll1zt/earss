defmodule Earss.FeedPoller do
  @moduledoc """
  Periodic GenServer that refreshes due feeds.

  Configuration (`config :earss, :poller`, overridable via env — see earss.env.example):

    * `:enabled` — default `true` in dev/prod, `false` in test
    * `:interval_ms` — tick period (default 5 minutes)
    * `:batch_size` — max feeds per tick (default 50)
    * `:max_concurrency` — parallel refreshes (default 5)
    * `:initial_delay_ms` — delay before first tick (default 1s)
    * `:timeout_ms` — per-feed refresh timeout (default 60s; slow adapters /
      paginated plugins may need more, e.g. `POLLER_TIMEOUT_MS=120000`)
  """

  use GenServer

  require Logger

  alias Earss.FeedScheduler
  alias Earss.Feeds
  alias Earss.Feeds.HostLimiter

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Trigger one poll cycle immediately (async).
  """
  def poll_now do
    GenServer.cast(__MODULE__, :poll)
  end

  @impl true
  def init(opts) do
    state = %{
      interval_ms: opt(opts, :interval_ms, 5 * 60 * 1000),
      batch_size: opt(opts, :batch_size, 50),
      max_concurrency: opt(opts, :max_concurrency, 5),
      timeout_ms: opt(opts, :timeout_ms, 60_000)
    }

    # First tick after a short delay so boot is not blocked by network.
    schedule_tick(opt(opts, :initial_delay_ms, 1_000))
    {:ok, state}
  end

  @impl true
  def handle_cast(:poll, state) do
    run_poll(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:tick, state) do
    run_poll(state)
    schedule_tick(state.interval_ms)
    {:noreply, state}
  end

  defp run_poll(state) do
    feeds =
      state.batch_size
      |> FeedScheduler.list_due_feeds()
      |> HostLimiter.interleave_by_host()

    if feeds != [] do
      Logger.info("FeedPoller: refreshing #{length(feeds)} due feed(s)")
    end

    feeds
    |> Task.async_stream(
      fn feed ->
        try do
          Feeds.refresh(feed)
        rescue
          e ->
            Logger.error(
              "FeedPoller: refresh crashed for feed #{feed.id}: #{Exception.message(e)}"
            )

            {:error, e}
        end
      end,
      max_concurrency: state.max_concurrency,
      timeout: state.timeout_ms,
      on_timeout: :kill_task
    )
    |> Stream.run()
  end

  defp schedule_tick(ms) do
    Process.send_after(self(), :tick, ms)
  end

  defp opt(opts, key, default) do
    Keyword.get(opts, key) ||
      Application.get_env(:earss, :poller, []) |> Keyword.get(key, default)
  end
end
