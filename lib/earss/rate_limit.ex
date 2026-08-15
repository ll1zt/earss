defmodule Earss.RateLimit do
  @moduledoc """
  In-memory rate limiter for inbound authentication endpoints (ETS-backed,
  no dependencies).

  Protects the operator password / Fever key from online brute force when
  the service is exposed publicly (e.g. Tailscale Funnel): each route+client
  key gets a sliding request window, and repeated authentication failures
  lock the key out for a cool-down period.

  Configuration (`config :earss, :rate_limit`):

    * `:enabled` — start the limiter (default `true`; tests disable it)
    * `:max_requests` — allowed requests per window (default `10`)
    * `:window_secs` — sliding window (default `60`)
    * `:max_failures` — failures within the window that trigger a lock
      (default `5`)
    * `:lock_secs` — lock duration after too many failures (default `300`)

  The limiter **fails open**: when the process is not running (disabled),
  `check/2` returns `:ok` — a crashed limiter must never lock the operator
  out of their own server.

  Client identity: `client_ip/1` prefers the first `X-Forwarded-For` value
  (set by the Tailscale Funnel proxy) and falls back to `remote_ip` (direct
  tailnet access).

  Start options (`:name`, `:table`, `:window_ms`, `:max_requests`,
  `:max_failures`, `:lock_ms`) exist so tests can run isolated instances;
  the app starts the default named instance.
  """

  use GenServer

  @name __MODULE__
  @table :earss_rate_limit

  @max_entries 10_000

  defstruct table: @table,
            window_ms: 60_000,
            max_requests: 10,
            max_failures: 5,
            lock_ms: 300_000

  ## Public API

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Check one request for `{route, key}`. Returns `:ok` or
  `{:error, :rate_limited}` (window exceeded or currently locked).
  """
  @spec check(atom(), String.t()) :: :ok | {:error, :rate_limited}
  def check(route, key) when is_atom(route) and is_binary(key) do
    if Process.whereis(@name) do
      GenServer.call(@name, {:check, {route, key}})
    else
      :ok
    end
  end

  @doc """
  Record a failed authentication for `{route, key}`. Enough failures within
  the window lock the key for `lock_secs`.
  """
  @spec report_failure(atom(), String.t()) :: :ok
  def report_failure(route, key) when is_atom(route) and is_binary(key) do
    if Process.whereis(@name) do
      GenServer.cast(@name, {:failure, {route, key}})
    end

    :ok
  end

  @doc """
  Client identity for rate limiting: first `X-Forwarded-For` hop (Tailscale
  Funnel sets it for public visitors), else `remote_ip` (direct tailnet).
  """
  @spec client_ip(Plug.Conn.t()) :: String.t()
  def client_ip(conn) do
    case Plug.Conn.get_req_header(conn, "x-forwarded-for") do
      [xff | _] ->
        xff
        |> String.split(",")
        |> List.first()
        |> String.trim()

      _ ->
        conn.remote_ip
        |> :inet.ntoa()
        |> to_string()
    end
  end

  ## GenServer

  @impl true
  def init(opts) do
    cfg = Application.get_env(:earss, :rate_limit, [])
    table = Keyword.get(opts, :table, @table)

    :ets.new(table, [:named_table, :set, :protected, read_concurrency: true])

    {:ok,
     %__MODULE__{
       table: table,
       window_ms: opts[:window_ms] || Keyword.get(cfg, :window_secs, 60) * 1_000,
       max_requests: opts[:max_requests] || Keyword.get(cfg, :max_requests, 10),
       max_failures: opts[:max_failures] || Keyword.get(cfg, :max_failures, 5),
       lock_ms: opts[:lock_ms] || Keyword.get(cfg, :lock_secs, 300) * 1_000
     }}
  end

  @impl true
  def handle_call({:check, key}, _from, state) do
    now = now_ms()

    case get_entry(state.table, key) do
      nil ->
        put_entry(state.table, key, %{hits: [now], fails: [], locked_until: nil, last_seen: now})
        maybe_cull(state.table)
        {:reply, :ok, state}

      %{locked_until: locked} when is_integer(locked) and locked > now ->
        {:reply, {:error, :rate_limited}, state}

      %{hits: hits} = entry ->
        hits = prune(hits, now, state.window_ms)

        if length(hits) >= state.max_requests do
          put_entry(state.table, key, %{entry | hits: [now | hits], last_seen: now})
          maybe_cull(state.table)
          {:reply, {:error, :rate_limited}, state}
        else
          put_entry(state.table, key, %{entry | hits: [now | hits], last_seen: now})
          maybe_cull(state.table)
          {:reply, :ok, state}
        end
    end
  end

  @impl true
  def handle_cast({:failure, key}, state) do
    now = now_ms()

    entry =
      case get_entry(state.table, key) do
        nil -> %{hits: [], fails: [], locked_until: nil, last_seen: now}
        %{locked_until: locked} = e when is_integer(locked) and locked > now -> e
        e -> e
      end

    fails = prune(entry.fails, now, state.window_ms)

    entry =
      if length(fails) + 1 >= state.max_failures do
        %{entry | fails: [], locked_until: now + state.lock_ms, last_seen: now}
      else
        %{entry | fails: [now | fails], last_seen: now}
      end

    put_entry(state.table, key, entry)
    maybe_cull(state.table)
    {:noreply, state}
  end

  ## Internals

  defp get_entry(table, key) do
    case :ets.lookup(table, key) do
      [{^key, entry}] -> entry
      [] -> nil
    end
  end

  defp put_entry(table, key, entry), do: :ets.insert(table, {key, entry})

  defp prune(times, now, window_ms) do
    Enum.filter(times, &(&1 > now - window_ms))
  end

  # Bound the table: an attacker spraying unique X-Forwarded-For values must
  # not grow it without limit. Drop the oldest-seen entries.
  defp maybe_cull(table) do
    size = :ets.info(table, :size)

    if size > @max_entries do
      table
      |> :ets.tab2list()
      |> Enum.sort_by(fn {_k, entry} -> entry.last_seen end)
      |> Enum.take(size - @max_entries)
      |> Enum.each(fn {k, _entry} -> :ets.delete(table, k) end)
    end

    :ok
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
