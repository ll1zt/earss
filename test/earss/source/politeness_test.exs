defmodule Earss.Source.PolitenessTest do
  use ExUnit.Case, async: true

  alias Earss.Source.Politeness

  test "default_plugin_intervals are conservative vs native stock" do
    i = Politeness.default_plugin_intervals()
    assert i.min_refresh_interval >= 30
    assert i.default_refresh_interval >= i.min_refresh_interval
    assert i.max_refresh_interval >= i.default_refresh_interval
  end

  test "clamp_interval" do
    assert Politeness.clamp_interval(5, 15, 100, 30) == 15
    assert Politeness.clamp_interval(50, 15, 100, 30) == 50
    assert Politeness.clamp_interval(500, 15, 100, 30) == 100
    assert Politeness.clamp_interval(nil, 15, 100, 30) == 30
  end

  test "host_key from https URL" do
    assert Politeness.host_key("https://WWW.Example.COM/path") == "www.example.com"
    assert Politeness.host_key("earss://telegram/channel/x") == nil
  end

  test "retry_after_seconds delta-seconds" do
    assert Politeness.retry_after_seconds(%{"retry-after" => "120"}) == 120
    assert Politeness.retry_after_seconds([{"Retry-After", "60"}]) == 60
  end

  test "retry_after_seconds HTTP-date" do
    future =
      DateTime.utc_now()
      |> DateTime.add(90, :second)
      |> Calendar.strftime("%a, %d %b %Y %H:%M:%S GMT")

    secs = Politeness.retry_after_seconds(%{"retry-after" => future})
    assert is_integer(secs)
    assert secs >= 0
    assert secs <= 120
  end
end
