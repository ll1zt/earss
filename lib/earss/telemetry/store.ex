defmodule Earss.Telemetry.Store do
  @moduledoc """
  In-memory aggregation of Earss telemetry events (ETS-free; plain GenServer
  state — event volume is low: per fetch / per tick).

  Powers `/admin/metrics`. Keeps, per event:

    * `counters` — outcome totals for `[:earss, :feed, :fetch]`, plain
      totals for the other events
    * `latency` — count / sum / min / max of the `duration` measurement
      (native units; the metrics page converts to ms)
    * `failures` — bounded list of failed feed fetches (feed_id, link,
      outcome, at) for the problem ranking

  Handlers only cast into the store process, so emitting processes are
  never blocked or crashed by aggregation. State resets on restart; there
  is no persistence (operator tooling can scrape it while the app runs).
  """

  use GenServer

  @name __MODULE__
  @recent_failures_limit 50
  @failure_outcomes [:http_error, :parse_error, :adapter_error, :error]

  defstruct started_at: nil,
            counters: %{},
            latency: %{},
            failures: [],
            recent_failures_limit: @recent_failures_limit

  ## Public API

  @doc """
  Start a store. `opts`:

    * `:name` — registered process name (default `#{inspect(@name)}`)
    * `:recent_failures` — max kept fetch failures (default `#{@recent_failures_limit}`)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Aggregation snapshot for the metrics page."
  @spec snapshot(GenServer.server()) :: map()
  def snapshot(store \\ @name), do: GenServer.call(store, :snapshot)

  @doc "Clear counters, latency and failures (keeps uptime)."
  @spec reset(GenServer.server()) :: :ok
  def reset(store \\ @name), do: GenServer.cast(store, :reset)

  @doc "Telemetry handler: cast the event into the store process."
  @spec handle_event([atom()], map(), map(), map()) :: :ok
  def handle_event(event, measurements, metadata, config) do
    store = Map.get(config, :store, @name)
    GenServer.cast(store, {:event, event, measurements, metadata})
    :ok
  end

  ## GenServer

  @impl true
  def init(opts) do
    {:ok,
     %__MODULE__{
       started_at: DateTime.utc_now(),
       failures: [],
       recent_failures_limit: Keyword.get(opts, :recent_failures, @recent_failures_limit)
     }}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, Map.drop(state, [:recent_failures_limit]), state}
  end

  @impl true
  def handle_cast(:reset, state) do
    {:noreply, %{state | counters: %{}, latency: %{}, failures: []}}
  end

  @impl true
  def handle_cast({:event, event, measurements, metadata}, state) do
    state =
      state
      |> bump_counter(event, metadata)
      |> bump_latency(event, measurements)
      |> maybe_record_failure(event, metadata)

    {:noreply, state}
  end

  ## Internals

  defp bump_counter(state, [:earss, :feed, :fetch] = event, metadata) do
    key = Map.get(metadata, :outcome, :unknown)
    put_counter(state, event, key)
  end

  defp bump_counter(state, event, _metadata), do: put_counter(state, event, :total)

  defp put_counter(state, event, key) do
    counters =
      state.counters
      |> Map.update(event, %{key => 1}, fn by_key ->
        Map.update(by_key, key, 1, &(&1 + 1))
      end)

    %{state | counters: counters}
  end

  defp bump_latency(state, event, measurements) do
    case Map.get(measurements, :duration) do
      duration when is_integer(duration) ->
        latency =
          Map.update(
            state.latency,
            event,
            %{count: 1, sum: duration, min: duration, max: duration},
            fn stats ->
              %{
                count: stats.count + 1,
                sum: stats.sum + duration,
                min: min(stats.min, duration),
                max: max(stats.max, duration)
              }
            end
          )

        %{state | latency: latency}

      _ ->
        state
    end
  end

  defp maybe_record_failure(state, [:earss, :feed, :fetch], metadata) do
    outcome = Map.get(metadata, :outcome, :unknown)

    if outcome in @failure_outcomes do
      failures =
        [
          %{
            feed_id: Map.get(metadata, :feed_id),
            link: Map.get(metadata, :link),
            outcome: outcome,
            at: DateTime.utc_now()
          }
          | state.failures
        ]
        |> Enum.take(state.recent_failures_limit)

      %{state | failures: failures}
    else
      state
    end
  end

  defp maybe_record_failure(state, _event, _metadata), do: state
end
