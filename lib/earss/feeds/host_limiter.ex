defmodule Earss.Feeds.HostLimiter do
  @moduledoc """
  Per-host crawl politeness for outbound feed HTTP.

  Limits concurrent in-flight requests and enforces a minimum interval between
  starts for the same host key. Optional cooldowns (e.g. after HTTP 429/503)
  block new checkouts until the freeze ends.

  Host keys should be lowercase HTTP hosts (`Earss.Source.Politeness.host_key/1`).
  When politeness is disabled, all operations succeed immediately (no queueing).

  Limits are read from Application env on each decision so operators (and tests)
  can tune without restarting the process.

  Configuration (`config :earss, :host_politeness`):

    * `:enabled` — default `true`
    * `:max_concurrent_per_host` — default `2`
    * `:min_interval_ms` — default `1000`
    * `:default_cooldown_ms` — used when `penalize/2` gets `nil` (default `60_000`)
    * `:checkout_timeout_ms` — max wait in `checkout/2` (default `30_000`)
  """

  use GenServer

  @name __MODULE__

  @type host :: String.t()

  defstruct hosts: %{}

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @doc """
  Acquire a slot for `host` before performing an outbound request.

  Blocks (up to `:checkout_timeout_ms`) until concurrent + min-interval and
  cooldown allow the request.

  Returns:

    * `:ok`
    * `{:error, :timeout}` after waiting too long
  """
  @spec checkout(host(), keyword()) :: :ok | {:error, :timeout}
  def checkout(host, opts \\ []) when is_binary(host) do
    host = normalize_host(host)

    if enabled?() do
      timeout = Keyword.get(opts, :timeout) || cfg(:checkout_timeout_ms, 30_000)

      try do
        GenServer.call(@name, {:checkout, host}, timeout + 500)
      catch
        :exit, {:timeout, _} -> {:error, :timeout}
        :exit, {:noproc, _} -> :ok
      end
    else
      :ok
    end
  end

  @doc "Release a previously checked-out slot."
  @spec checkin(host()) :: :ok
  def checkin(host) when is_binary(host) do
    host = normalize_host(host)

    if enabled?() and Process.whereis(@name) do
      GenServer.cast(@name, {:checkin, host})
    end

    :ok
  end

  @doc """
  Freeze `host` after a rate-limit style response.

  `retry_after_secs` is preferred when the remote sent `Retry-After`; otherwise
  `:default_cooldown_ms` is used. `0` clears any active cooldown.
  """
  @spec penalize(host(), non_neg_integer() | nil) :: :ok
  def penalize(host, retry_after_secs) when is_binary(host) do
    host = normalize_host(host)

    if enabled?() and Process.whereis(@name) do
      GenServer.cast(@name, {:penalize, host, retry_after_secs})
    end

    :ok
  end

  @doc false
  def enabled? do
    cfg(:enabled, true) == true
  end

  @doc """
  Stable host key for a URL, falling back to `\"unknown\"`.
  """
  @spec host_key_for(String.t() | URI.t() | nil) :: host()
  def host_key_for(nil), do: "unknown"

  def host_key_for(url) do
    case Earss.Source.Politeness.host_key(url) do
      nil -> "unknown"
      host -> host
    end
  end

  @doc """
  Interleave feeds by host so a poll batch does not start with a long run of
  the same domain.
  """
  @spec interleave_by_host([map()]) :: [map()]
  def interleave_by_host([]), do: []

  def interleave_by_host(feeds) when is_list(feeds) do
    feeds
    |> Enum.group_by(&feed_host/1)
    |> Map.values()
    |> round_robin([])
  end

  # ---------------------------------------------------------------------------
  # GenServer
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    {:ok, %__MODULE__{hosts: %{}}}
  end

  @impl true
  def handle_call({:checkout, host}, from, state) do
    if enabled?() do
      limits = limits()
      now = mono_ms()
      entry = Map.get(state.hosts, host, new_entry())

      case try_grant(entry, limits, now) do
        {:ok, entry2} ->
          {:reply, :ok, put_host(state, host, entry2)}

        {:wait, entry2, delay_ms} ->
          entry3 = %{entry2 | waiters: :queue.in(from, entry2.waiters)}
          state = put_host(state, host, entry3)
          {:noreply, schedule_wake(state, host, delay_ms)}
      end
    else
      {:reply, :ok, state}
    end
  end

  @impl true
  def handle_cast({:checkin, host}, state) do
    limits = limits()
    now = mono_ms()
    entry = Map.get(state.hosts, host, new_entry())
    entry = %{entry | in_flight: max(entry.in_flight - 1, 0)}
    {entry, replies, delay_ms} = drain_waiters(entry, limits, now)

    state = put_host(state, host, entry)
    Enum.each(replies, fn from -> GenServer.reply(from, :ok) end)

    state =
      if delay_ms do
        schedule_wake(state, host, delay_ms)
      else
        state
      end

    {:noreply, maybe_prune(state, host)}
  end

  @impl true
  def handle_cast({:penalize, host, retry_after_secs}, state) do
    limits = limits()
    now = mono_ms()
    entry = Map.get(state.hosts, host, new_entry())

    cooldown_ms =
      case retry_after_secs do
        n when is_integer(n) and n > 0 -> n * 1_000
        0 -> 0
        _ -> limits.default_cooldown_ms
      end

    entry =
      if cooldown_ms == 0 do
        %{entry | cooldown_until: nil}
      else
        until = now + cooldown_ms
        prev = entry.cooldown_until

        %{
          entry
          | cooldown_until: if(is_integer(prev) and prev > until, do: prev, else: until)
        }
      end

    state = put_host(state, host, entry)

    state =
      if cooldown_ms > 0 do
        schedule_wake(state, host, cooldown_ms)
      else
        {entry, replies, delay_ms} = drain_waiters(entry, limits, now)
        state = put_host(state, host, entry)
        Enum.each(replies, fn from -> GenServer.reply(from, :ok) end)

        if delay_ms, do: schedule_wake(state, host, delay_ms), else: state
      end

    {:noreply, state}
  end

  @impl true
  def handle_info({:wake, host}, state) do
    limits = limits()
    now = mono_ms()

    case Map.get(state.hosts, host) do
      nil ->
        {:noreply, state}

      entry ->
        {entry, replies, delay_ms} = drain_waiters(entry, limits, now)
        state = put_host(state, host, entry)
        Enum.each(replies, fn from -> GenServer.reply(from, :ok) end)

        state =
          if delay_ms do
            schedule_wake(state, host, delay_ms)
          else
            state
          end

        {:noreply, maybe_prune(state, host)}
    end
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp limits do
    %{
      max_concurrent: max(cfg(:max_concurrent_per_host, 2), 1),
      min_interval_ms: max(cfg(:min_interval_ms, 1_000), 0),
      default_cooldown_ms: max(cfg(:default_cooldown_ms, 60_000), 0)
    }
  end

  defp try_grant(entry, limits, now) do
    cond do
      cooldown?(entry, now) ->
        {:wait, entry, max(entry.cooldown_until - now, 1)}

      entry.in_flight >= limits.max_concurrent ->
        # Primary release path is checkin; soft timer is a backup.
        {:wait, entry, 5_000}

      too_soon?(entry, limits, now) ->
        delay = limits.min_interval_ms - (now - entry.last_started_at)
        {:wait, entry, max(delay, 1)}

      true ->
        {:ok,
         %{
           entry
           | in_flight: entry.in_flight + 1,
             last_started_at: now
         }}
    end
  end

  defp drain_waiters(entry, limits, now) do
    do_drain(entry, limits, now, [], nil)
  end

  defp do_drain(entry, limits, now, acc, pending_delay) do
    case :queue.out(entry.waiters) do
      {:empty, _} ->
        {entry, Enum.reverse(acc), pending_delay}

      {{:value, from}, rest} ->
        entry = %{entry | waiters: rest}

        case try_grant(entry, limits, now) do
          {:ok, entry2} ->
            do_drain(entry2, limits, now, [from | acc], pending_delay)

          {:wait, entry2, delay_ms} ->
            entry2 = %{entry2 | waiters: :queue.in_r(from, entry2.waiters)}
            {entry2, Enum.reverse(acc), delay_ms}
        end
    end
  end

  defp schedule_wake(state, host, delay_ms) when is_integer(delay_ms) and delay_ms > 0 do
    Process.send_after(self(), {:wake, host}, delay_ms)
    state
  end

  defp schedule_wake(state, _host, _), do: state

  defp cooldown?(%{cooldown_until: nil}, _now), do: false
  defp cooldown?(%{cooldown_until: until}, now) when is_integer(until), do: now < until

  defp too_soon?(%{last_started_at: nil}, _limits, _now), do: false

  defp too_soon?(%{last_started_at: last}, limits, now) do
    limits.min_interval_ms > 0 and now - last < limits.min_interval_ms
  end

  defp new_entry do
    %{in_flight: 0, last_started_at: nil, cooldown_until: nil, waiters: :queue.new()}
  end

  defp put_host(state, host, entry), do: %{state | hosts: Map.put(state.hosts, host, entry)}

  defp maybe_prune(state, host) do
    case Map.get(state.hosts, host) do
      %{in_flight: 0, waiters: q} = entry ->
        now = mono_ms()
        limits = limits()

        # Keep the entry while cooldown or min-interval still apply so
        # last_started_at / cooldown_until are not forgotten.
        busy? =
          not :queue.is_empty(q) or cooldown?(entry, now) or too_soon?(entry, limits, now)

        if busy? do
          state
        else
          %{state | hosts: Map.delete(state.hosts, host)}
        end

      _ ->
        state
    end
  end

  defp mono_ms, do: System.monotonic_time(:millisecond)

  defp normalize_host(host) when is_binary(host) do
    host |> String.trim() |> String.downcase()
  end

  defp feed_host(feed) do
    link = Map.get(feed, :link) || Map.get(feed, "link")
    host_key_for(link)
  end

  defp round_robin([], acc), do: Enum.reverse(acc)

  defp round_robin(groups, acc) do
    {next_acc, next_groups} =
      Enum.reduce(groups, {acc, []}, fn
        [], {a, g} ->
          {a, g}

        [h | t], {a, g} ->
          {[h | a], if(t == [], do: g, else: [t | g])}
      end)

    round_robin(Enum.reverse(next_groups), next_acc)
  end

  defp cfg(key, default) do
    Application.get_env(:earss, :host_politeness, []) |> Keyword.get(key, default)
  end
end
