defmodule Earss.RateLimitTest do
  use ExUnit.Case, async: false

  alias Earss.RateLimit

  # The app-level limiter is disabled in test config; these tests start
  # isolated instances with their own name/table/limits.
  defp start_limiter!(name, table, opts) do
    start_supervised!(%{
      id: :rate_limit_test,
      start: {RateLimit, :start_link, [Keyword.merge([name: name, table: table], opts)]}
    })
  end

  defp check(name, key), do: GenServer.call(name, {:check, {name, key}})
  defp fail(name, key), do: GenServer.cast(name, {:failure, {name, key}})

  test "allows up to max_requests within the window" do
    name = :"rl_a_#{System.unique_integer([:positive])}"
    table = :"rl_a_table_#{System.unique_integer([:positive])}"

    start_limiter!(name, table,
      window_ms: 60_000,
      max_requests: 3,
      max_failures: 2,
      lock_ms: 60_000
    )

    assert check(name, "ip1") == :ok
    assert check(name, "ip1") == :ok
    assert check(name, "ip1") == :ok
    assert check(name, "ip1") == {:error, :rate_limited}
  end

  test "locks a key after repeated failures" do
    name = :"rl_b_#{System.unique_integer([:positive])}"
    table = :"rl_b_table_#{System.unique_integer([:positive])}"

    start_limiter!(name, table,
      window_ms: 60_000,
      max_requests: 10,
      max_failures: 2,
      lock_ms: 60_000
    )

    fail(name, "ip2")
    assert check(name, "ip2") == :ok
    fail(name, "ip2")

    # locked: rejected even though the request window is far from full
    assert check(name, "ip2") == {:error, :rate_limited}
  end

  test "lock expires after lock_ms" do
    name = :"rl_c_#{System.unique_integer([:positive])}"
    table = :"rl_c_table_#{System.unique_integer([:positive])}"
    start_limiter!(name, table, window_ms: 60_000, max_requests: 10, max_failures: 1, lock_ms: 40)

    fail(name, "ip3")
    assert check(name, "ip3") == {:error, :rate_limited}

    Process.sleep(60)
    assert check(name, "ip3") == :ok
  end

  test "different keys are independent" do
    name = :"rl_d_#{System.unique_integer([:positive])}"
    table = :"rl_d_table_#{System.unique_integer([:positive])}"

    start_limiter!(name, table,
      window_ms: 60_000,
      max_requests: 10,
      max_failures: 2,
      lock_ms: 60_000
    )

    fail(name, "ip_a")
    fail(name, "ip_a")
    assert check(name, "ip_a") == {:error, :rate_limited}
    assert check(name, "ip_b") == :ok
  end

  test "client_ip prefers the first x-forwarded-for hop" do
    conn =
      Plug.Test.conn(:get, "/")
      |> Plug.Conn.put_req_header("x-forwarded-for", "203.0.113.7, 100.100.100.1")

    assert RateLimit.client_ip(conn) == "203.0.113.7"
  end

  test "client_ip falls back to remote_ip" do
    assert RateLimit.client_ip(Plug.Test.conn(:get, "/")) == "127.0.0.1"
  end
end
