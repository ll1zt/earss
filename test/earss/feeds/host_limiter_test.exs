defmodule Earss.Feeds.HostLimiterTest do
  use ExUnit.Case, async: false

  alias Earss.Feeds.HostLimiter

  setup do
    prev = Application.get_env(:earss, :host_politeness, [])

    Application.put_env(:earss, :host_politeness,
      enabled: true,
      max_concurrent_per_host: 1,
      min_interval_ms: 0,
      default_cooldown_ms: 200,
      checkout_timeout_ms: 1_000
    )

    on_exit(fn ->
      Application.put_env(:earss, :host_politeness, prev)
    end)

    :ok
  end

  test "checkout grants and checkin releases concurrent slot" do
    host = "concurrent-#{System.unique_integer([:positive])}.example"

    assert :ok = HostLimiter.checkout(host)

    task =
      Task.async(fn ->
        HostLimiter.checkout(host, timeout: 500)
      end)

    # Second checkout waits while first holds the slot.
    Process.sleep(80)
    assert Process.alive?(task.pid)

    assert :ok = HostLimiter.checkin(host)
    assert :ok = Task.await(task, 1_000)
    assert :ok = HostLimiter.checkin(host)
  end

  test "min_interval delays second start on same host" do
    host = "interval-#{System.unique_integer([:positive])}.example"

    Application.put_env(:earss, :host_politeness,
      enabled: true,
      max_concurrent_per_host: 4,
      min_interval_ms: 150,
      default_cooldown_ms: 200,
      checkout_timeout_ms: 1_000
    )

    t0 = System.monotonic_time(:millisecond)
    assert :ok = HostLimiter.checkout(host)
    assert :ok = HostLimiter.checkin(host)

    assert :ok = HostLimiter.checkout(host)
    t1 = System.monotonic_time(:millisecond)
    assert :ok = HostLimiter.checkin(host)

    assert t1 - t0 >= 120
  end

  test "penalize blocks checkout until cooldown ends" do
    host = "cooldown-#{System.unique_integer([:positive])}.example"

    Application.put_env(:earss, :host_politeness,
      enabled: true,
      max_concurrent_per_host: 4,
      min_interval_ms: 0,
      default_cooldown_ms: 250,
      checkout_timeout_ms: 2_000
    )

    HostLimiter.penalize(host, 1)
    # Allow cast to land
    Process.sleep(20)

    t0 = System.monotonic_time(:millisecond)
    assert :ok = HostLimiter.checkout(host, timeout: 2_000)
    t1 = System.monotonic_time(:millisecond)
    assert :ok = HostLimiter.checkin(host)

    assert t1 - t0 >= 800
  end

  test "checkout times out when slot never frees" do
    host = "timeout-#{System.unique_integer([:positive])}.example"

    Application.put_env(:earss, :host_politeness,
      enabled: true,
      max_concurrent_per_host: 1,
      min_interval_ms: 0,
      default_cooldown_ms: 200,
      checkout_timeout_ms: 200
    )

    assert :ok = HostLimiter.checkout(host)
    assert {:error, :timeout} = HostLimiter.checkout(host, timeout: 150)
    assert :ok = HostLimiter.checkin(host)
  end

  test "disabled politeness is a no-op" do
    host = "disabled-#{System.unique_integer([:positive])}.example"

    Application.put_env(:earss, :host_politeness,
      enabled: false,
      max_concurrent_per_host: 1,
      min_interval_ms: 0,
      default_cooldown_ms: 200,
      checkout_timeout_ms: 200
    )

    assert :ok = HostLimiter.checkout(host)
    assert :ok = HostLimiter.checkout(host)
  end

  test "interleave_by_host round-robins domains" do
    feeds = [
      %{link: "https://a.example/1"},
      %{link: "https://a.example/2"},
      %{link: "https://b.example/1"},
      %{link: "https://c.example/1"},
      %{link: "https://a.example/3"}
    ]

    out = HostLimiter.interleave_by_host(feeds)
    hosts = Enum.map(out, &HostLimiter.host_key_for(&1.link))

    assert length(out) == 5
    # First three should be different hosts when three groups exist
    assert hosts |> Enum.take(3) |> Enum.uniq() |> length() == 3
  end

  test "host_key_for falls back for earss:// and nil" do
    assert HostLimiter.host_key_for("https://WWW.Example.COM/x") == "www.example.com"
    assert HostLimiter.host_key_for("earss://telegram/channel/x") == "unknown"
    assert HostLimiter.host_key_for(nil) == "unknown"
  end
end
