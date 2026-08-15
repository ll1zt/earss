defmodule Earss.Admin.HelpersTest do
  use ExUnit.Case, async: true

  alias Earss.Admin.Helpers
  alias Earss.Admin.HTML

  describe "format_error/1" do
    test "maps friendly atoms instead of raw atom names" do
      assert Helpers.format_error(:pick_a_category) == "pick a target category first"
      assert Helpers.format_error(:missing_feed) == "feed no longer exists"
      assert Helpers.format_error(:timeout) == "timed out"
      assert Helpers.format_error(:nxdomain) == "DNS lookup failed"
    end

    test "humanizes unknown atoms" do
      assert Helpers.format_error(:some_new_error) == "some new error"
    end

    test "renders http/parse/adapter tuples" do
      assert Helpers.format_error({:http, 404}) == "HTTP 404"
      assert Helpers.format_error({:http, %{reason: :nxdomain}}) == "DNS lookup failed"
      assert Helpers.format_error({:parse, :bad_xml}) == "feed could not be parsed"
      assert Helpers.format_error({:adapter, :timeout}) == "timed out"

      assert Helpers.format_error({:http, {:host_limiter, :timeout, "h"}}) ==
               "{:host_limiter, :timeout, \"h\"}"
    end

    test "passes binaries through untouched" do
      assert Helpers.format_error("already parsed message") == "already parsed message"
    end
  end

  describe "format_interval_ms/1" do
    test "human units" do
      assert Helpers.format_interval_ms(300_000) == "5 min"
      assert Helpers.format_interval_ms(60_000) == "1 min"
      assert Helpers.format_interval_ms(86_400_000) == "1.0 d"
      assert Helpers.format_interval_ms(3_600_000) == "1.0 h"
      assert Helpers.format_interval_ms(1_000) == "1 s"
      assert Helpers.format_interval_ms(500) == "500 ms"
      assert Helpers.format_interval_ms(nil) == "—"
    end
  end

  describe "paginate/3 and showing_range/2" do
    test "slices with clamped pages" do
      items = Enum.to_list(1..120)

      assert {Enum.to_list(1..50), 1, 3} = Helpers.paginate(items, 1)
      assert {Enum.to_list(51..100), 2, 3} = Helpers.paginate(items, 2)
      assert {Enum.to_list(101..120), 3, 3} = Helpers.paginate(items, 3)

      # out-of-range clamps into the valid range
      assert {Enum.to_list(101..120), 3, 3} = Helpers.paginate(items, 99)
      assert {Enum.to_list(1..50), 1, 3} = Helpers.paginate(items, nil)
      assert {Enum.to_list(1..50), 1, 3} = Helpers.paginate(items, 0)
    end

    test "empty list is one empty page" do
      assert {[], 1, 1} = Helpers.paginate([], 1)
    end

    test "showing_range" do
      assert Helpers.showing_range(1, 0) == "0"
      assert Helpers.showing_range(1, 120) == "1–50"
      assert Helpers.showing_range(2, 120) == "51–100"
      assert Helpers.showing_range(3, 120) == "101–120"
    end
  end

  describe "HTML.time_ago/1" do
    test "past timestamps render relative with absolute tooltip" do
      dt = DateTime.add(DateTime.utc_now(), -5 * 60 - 10, :second)
      html = HTML.time_ago(dt)
      assert html =~ "5m ago"
      assert html =~ ~s(title="#{HTML.format_dt(dt)}")
    end

    test "future timestamps render in-relative" do
      dt = DateTime.add(DateTime.utc_now(), 5 * 60, :second)
      assert HTML.time_ago(dt) =~ "in 5m"
    end

    test "older than a week falls back to absolute" do
      dt = DateTime.add(DateTime.utc_now(), -8 * 86_400, :second)
      assert HTML.time_ago(dt) =~ HTML.format_dt(dt)
    end

    test "nil renders an em dash" do
      assert HTML.time_ago(nil) == "—"
    end
  end
end
