defmodule Earss.RateLimit do
  @moduledoc """
  In-memory rate limiter for inbound authentication failures (ETS-backed,
  no dependencies).

  Design rule: **only failures are limited — a correct credential always
  passes and clears the key's state**. Rate limiting must stop brute force
  without ever letting an attacker lock the operator out (verified the hard
  way: limit-before-verify turned 5 wrong guesses into a 5-minute lockout
  of the correct password).

  Two layers:

    * per-key — failures per `{route, key}` within a sliding window lock the
      key for a cool-down (`max_failures` / `window_secs` / `lock_secs`)
    * global backstop — failures per route across ALL keys; an attacker
      rotating `X-Forwarded-For` cannot evade the per-key lock, so the
      route-wide counter bounds the overall guessing rate

  Client identity (`client_ip/1`): the first `X-Forwarded-For` hop is
  honoured **only when the direct peer (`remote_ip`) is inside a configured
  trusted proxy CIDR** (e.g. `100.64.0.0/10` behind Tailscale Funnel).
  Otherwise XFF is ignored — a directly-connecting attacker can forge it.
  Trust nothing by default.

  Configuration (`config :earss, :rate_limit`):

    * `:enabled` — start the limiter (default `true`; tests disable it)
    * `:max_failures` — per-key failures in the window before a lock
      (default `5`)
    * `:window_secs` — sliding window for failures (default `60`)
    * `:lock_secs` — per-key lock duration (default `300`)
    * `:global_max_failures` — route-wide failures in the window before the
      whole route is throttled (default `30`)
    * `:trusted_proxies` — CIDR strings allowed to set X-Forwarded-For
      (default `[]`)

  The limiter **fails open**: when the process is not running (disabled),
  every call succeeds — a crashed limiter must never lock the operator out.
  """

  use GenServer

  import Bitwise

  @name __MODULE__
  @table :earss_rate_limit

  @max_entries 10_000

  defstruct table: @table,
            window_ms: 60_000,
            max_failures: 5,
            lock_ms: 300_000,
            global_max_failures: 30,
            global: %{}

  ## Public API

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Record a failed authentication for `{route, key}`.

  Returns `:ok` (failure accepted, response is the caller's business) or
  `{:error, :rate_limited}` when the key is locked or the route-wide
  backstop is engaged.
  """
  @spec failure(atom(), String.t()) :: :ok | {:error, :rate_limited}
  def failure(route, key) when is_atom(route) and is_binary(key) do
    if Process.whereis(@name) do
      GenServer.call(@name, {:failure, {route, key}})
    else
      :ok
    end
  end

  @doc """
  Clear a key's state (a correct credential just verified — always unlock).
  """
  @spec clear(atom(), String.t()) :: :ok
  def clear(route, key) when is_atom(route) and is_binary(key) do
    if Process.whereis(@name) do
      GenServer.call(@name, {:clear, {route, key}})
    end

    :ok
  end

  @doc """
  Client identity for rate limiting: first `X-Forwarded-For` hop when (and
  only when) the direct peer is a trusted proxy; `remote_ip` otherwise.
  """
  @spec client_ip(Plug.Conn.t()) :: String.t()
  def client_ip(conn) do
    remote = remote_ip_string(conn)

    if trusted_proxy?(conn.remote_ip) do
      case Plug.Conn.get_req_header(conn, "x-forwarded-for") do
        [xff | _] ->
          xff
          |> String.split(",")
          |> List.first()
          |> String.trim()

        _ ->
          remote
      end
    else
      remote
    end
  end

  @doc "Whether an IP tuple falls inside a configured trusted-proxy CIDR."
  @spec trusted_proxy?(:inet.ip_address()) :: boolean()
  def trusted_proxy?(ip) do
    :earss
    |> Application.get_env(:rate_limit, [])
    |> Keyword.get(:trusted_proxies, [])
    |> Enum.any?(fn cidr -> in_cidr?(ip, cidr) end)
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
       max_failures: opts[:max_failures] || Keyword.get(cfg, :max_failures, 5),
       lock_ms: opts[:lock_ms] || Keyword.get(cfg, :lock_secs, 300) * 1_000,
       global_max_failures:
         opts[:global_max_failures] || Keyword.get(cfg, :global_max_failures, 30)
     }}
  end

  @impl true
  def handle_call({:failure, {route, _key} = key}, _from, state) do
    now = now_ms()

    cond do
      global_throttled?(state, route, now) ->
        {:reply, {:error, :rate_limited}, state}

      key_locked?(state, key, now) ->
        {:reply, {:error, :rate_limited}, state}

      true ->
        state = record_failure(state, key, now)
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:clear, key}, _from, state) do
    :ets.delete(state.table, key)
    {:reply, :ok, state}
  end

  ## Internals

  defp record_failure(state, key, now) do
    entry =
      case get_entry(state.table, key) do
        nil -> %{fails: [], locked_until: nil, last_seen: now}
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

    # route-wide backstop (the caller's reply consults this after the fact)
    global =
      Map.update(state.global, elem(key, 0), [now], &[now | prune(&1, now, state.window_ms)])

    %{state | global: global}
  end

  defp global_throttled?(state, route, now) do
    case Map.get(state.global, route) do
      nil -> false
      times -> length(prune(times, now, state.window_ms)) >= state.global_max_failures
    end
  end

  defp key_locked?(state, key, now) do
    case get_entry(state.table, key) do
      %{locked_until: locked} -> is_integer(locked) and locked > now
      _ -> false
    end
  end

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

  # Bound the table: sprayed keys must not grow it without limit.
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

  defp remote_ip_string(conn) do
    conn.remote_ip
    |> :inet.ntoa()
    |> to_string()
  end

  ## CIDR matching (IPv4 dotted-decimal only — sufficient for proxy ranges)

  defp in_cidr?(ip, cidr) when is_binary(cidr) do
    case String.split(cidr, "/") do
      [addr, len] ->
        case Integer.parse(len) do
          {bits, ""} when bits in 1..32 ->
            case parse_ipv4(addr) do
              {:ok, net} -> ipv4_mask_match?(ip, net, bits)
              :error -> false
            end

          _ ->
            false
        end

      _ ->
        false
    end
  end

  defp in_cidr?(_, _), do: false

  defp parse_ipv4(addr) do
    case :inet.parse_address(String.to_charlist(addr)) do
      {:ok, ip} when tuple_size(ip) == 4 -> {:ok, ip}
      _ -> :error
    end
  end

  defp ipv4_mask_match?(ip, net, bits) when tuple_size(ip) == 4 and tuple_size(net) == 4 do
    ip_bits = ipv4_to_int(ip)
    net_bits = ipv4_to_int(net)

    # shift both so only the top `bits` remain
    ip_bits >>> (32 - bits) == net_bits >>> (32 - bits)
  end

  defp ipv4_mask_match?(_, _, _), do: false

  defp ipv4_to_int({a, b, c, d}) do
    a <<< 24 ||| b <<< 16 ||| c <<< 8 ||| d
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
