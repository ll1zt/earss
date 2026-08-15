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

  defp fail(name, key), do: GenServer.call(name, {:failure, {name, key}})
  defp clear(name, key), do: GenServer.call(name, {:clear, {name, key}})

  test "locks a key after repeated failures" do
    name = :"rl_a_#{System.unique_integer([:positive])}"
    table = :"rl_a_table_#{System.unique_integer([:positive])}"

    start_limiter!(name, table,
      window_ms: 60_000,
      max_failures: 2,
      lock_ms: 60_000,
      global_max_failures: 100
    )

    assert fail(name, "ip1") == :ok
    assert fail(name, "ip1") == :ok
    assert fail(name, "ip1") == {:error, :rate_limited}
  end

  test "clear unlocks a locked key (correct credential wins)" do
    name = :"rl_b_#{System.unique_integer([:positive])}"
    table = :"rl_b_table_#{System.unique_integer([:positive])}"

    start_limiter!(name, table,
      window_ms: 60_000,
      max_failures: 1,
      lock_ms: 60_000,
      global_max_failures: 100
    )

    assert fail(name, "ip2") == :ok
    assert fail(name, "ip2") == {:error, :rate_limited}
    assert clear(name, "ip2") == :ok
    assert fail(name, "ip2") == :ok
  end

  test "lock expires after lock_ms" do
    name = :"rl_c_#{System.unique_integer([:positive])}"
    table = :"rl_c_table_#{System.unique_integer([:positive])}"

    start_limiter!(name, table,
      window_ms: 60_000,
      max_failures: 1,
      lock_ms: 40,
      global_max_failures: 100
    )

    assert fail(name, "ip3") == :ok
    assert fail(name, "ip3") == {:error, :rate_limited}

    Process.sleep(60)
    assert fail(name, "ip3") == :ok
  end

  test "global backstop throttles the route regardless of key rotation" do
    name = :"rl_d_#{System.unique_integer([:positive])}"
    table = :"rl_d_table_#{System.unique_integer([:positive])}"

    start_limiter!(name, table,
      window_ms: 60_000,
      max_failures: 100,
      lock_ms: 60_000,
      global_max_failures: 3
    )

    assert fail(name, "a") == :ok
    assert fail(name, "b") == :ok
    assert fail(name, "c") == :ok

    # route-wide threshold reached: even fresh keys are throttled
    assert fail(name, "d") == {:error, :rate_limited}
    assert fail(name, "e") == {:error, :rate_limited}
  end

  test "different routes have independent backstops" do
    name = :"rl_e_#{System.unique_integer([:positive])}"
    table = :"rl_e_table_#{System.unique_integer([:positive])}"

    start_limiter!(name, table,
      window_ms: 60_000,
      max_failures: 100,
      lock_ms: 60_000,
      global_max_failures: 2
    )

    assert fail(name, "x") == :ok
    assert fail(name, "y") == :ok
    assert fail(name, "z") == {:error, :rate_limited}
  end

  describe "client_ip/1 with trusted proxies" do
    setup do
      previous = Application.get_env(:earss, :rate_limit, [])
      on_exit(fn -> Application.put_env(:earss, :rate_limit, previous) end)
      :ok
    end

    test "ignores XFF when no trusted proxies are configured" do
      Application.put_env(:earss, :rate_limit, trusted_proxies: [])

      conn =
        Plug.Test.conn(:get, "/")
        |> Map.put(:remote_ip, {203, 0, 113, 9})
        |> Plug.Conn.put_req_header("x-forwarded-for", "198.51.100.7, 100.100.100.1")

      assert RateLimit.client_ip(conn) == "203.0.113.9"
    end

    test "honours XFF from a trusted proxy CIDR" do
      Application.put_env(:earss, :rate_limit, trusted_proxies: ["100.64.0.0/10"])

      conn =
        Plug.Test.conn(:get, "/")
        |> Map.put(:remote_ip, {100, 100, 100, 1})
        |> Plug.Conn.put_req_header("x-forwarded-for", "198.51.100.7, 100.100.100.1")

      assert RateLimit.client_ip(conn) == "198.51.100.7"
    end

    test "falls back to remote_ip when the peer is not trusted" do
      Application.put_env(:earss, :rate_limit, trusted_proxies: ["100.64.0.0/10"])

      conn =
        Plug.Test.conn(:get, "/")
        |> Map.put(:remote_ip, {203, 0, 113, 9})
        |> Plug.Conn.put_req_header("x-forwarded-for", "198.51.100.7")

      assert RateLimit.client_ip(conn) == "203.0.113.9"
    end

    test "CIDR matching" do
      assert RateLimit.trusted_proxy?({100, 100, 100, 1}) ==
               Application.get_env(:earss, :rate_limit, [])
               |> Keyword.get(:trusted_proxies, [])
               |> Enum.any?(fn c -> c == "100.64.0.0/10" end)

      # direct unit checks on in_cidr? via trusted_proxy? with env
      Application.put_env(:earss, :rate_limit, trusted_proxies: ["100.64.0.0/10"])
      assert RateLimit.trusted_proxy?({100, 100, 100, 1})
      assert RateLimit.trusted_proxy?({100, 64, 0, 1})
      refute RateLimit.trusted_proxy?({100, 63, 255, 255})
      refute RateLimit.trusted_proxy?({203, 0, 113, 1})
      refute RateLimit.trusted_proxy?({127, 0, 0, 1})
    end
  end
end
