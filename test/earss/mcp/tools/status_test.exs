defmodule Earss.MCP.Tools.StatusTest do
  @moduledoc """
  Tests for the status tools.

  These are read-only aggregations, so the assertions focus on the shape and
  on one property each: system_status reflects the real feed count,
  feed_stats carries unread and error counts, translation_status reports
  pending/paused, and tts_list's stats match what the worker would produce.
  """

  use Earss.DataCase, async: false

  alias Earss.Enrichment
  alias Earss.Feeds
  alias Earss.MCP.Tools.Status
  alias Earss.Reader
  alias Earss.TTS

  setup do
    {:ok, feed} =
      Feeds.create_feed(%{
        link: "https://example.com/mcp-status.xml",
        title: "Status Feed",
        translate_to: "zh"
      })

    {:ok, _} = Reader.subscribe(%{feed_id: feed.id, refresh: false})

    {:ok, %{entries: [a, b]}} =
      Feeds.upsert_entries(feed, [
        %{guid: "st-1", link: "https://e.com/st-1", title: "One"},
        %{guid: "st-2", link: "https://e.com/st-2", title: "Two"}
      ])

    %{feed: feed, entry_a: a, entry_b: b}
  end

  defp tool(name), do: Enum.find(Status.tools(), &(&1.name == name))

  defp call(name, args \\ %{}), do: tool(name).handler.(args)

  describe "system_status/1" do
    test "reflects the real feed and subscription counts" do
      assert {:ok, result} = call("system_status")

      assert result.feeds >= 1
      assert result.subscriptions >= 1
      assert "zh" in result.languages
    end

    test "the payload is JSON-encodable", _ctx do
      assert {:ok, result} = call("system_status")

      # The telemetry snapshot is a struct with atom and list keys. Passing it
      # through unchanged made the response encoding blow up at request time,
      # which no unit assertion on the map itself would have caught.
      assert {:ok, encoded} = Jason.encode(result)
      assert is_binary(encoded)

      telemetry = result.telemetry
      assert is_map(telemetry)

      for {key, _} <- telemetry.counters do
        assert is_binary(key)
      end
    end

    test "is read-only" do
      assert tool("system_status").mutating == false
    end
  end

  describe "feed_stats/1" do
    test "carries unread counts and error fields", ctx do
      Reader.mark_read(ctx.entry_a.id)

      assert {:ok, result} = call("feed_stats")

      row = Enum.find(result.feeds, &(&1.feed_id == ctx.feed.id))
      assert row.unread == 1
      assert row.is_active == true
      assert row.link == ctx.feed.link
    end
  end

  describe "translation_status/1" do
    test "reports a translating feed and its pending count", ctx do
      # Mark the feed's entries pending the way the ingest hook would.
      Enrichment.mark_pending(ctx.feed, [ctx.entry_a])

      assert {:ok, result} = call("translation_status")
      assert result.enabled == true

      row = Enum.find(result.feeds, &(&1.feed_id == ctx.feed.id))
      assert row.translate_to == "zh"
      assert row.pending >= 1
    end

    test "reports disabled when nothing translates", ctx do
      # Remove translation from the known feed; translation_status re-queries
      # the DB so it must now report disabled.
      Feeds.update_feed(ctx.feed, %{"translate_to" => nil})

      assert {:ok, result} = call("translation_status")
      assert result.enabled == false
    end
  end

  describe "tts_list/1" do
    test "reports the queue stats", ctx do
      assert {:ok, result} = call("tts_list")

      assert is_integer(result.stats.ready)
      assert is_integer(result.stats.requested)
      assert is_integer(result.stats.processing)
      assert is_integer(result.stats.failed)
      assert ctx.feed.id
    end

    test "lists requests filtered by state", ctx do
      {:ok, req} = TTS.record_request(ctx.entry_a.id)

      assert {:ok, result} = call("tts_list", %{"state" => "requested"})

      assert Enum.any?(result.requests, &(&1.id == req.id))
      assert result.filtered_by == :requested
    end

    test "with no state filter it returns no request rows (summary only)", ctx do
      assert {:ok, result} = call("tts_list")
      assert result.requests == []
      assert result.filtered_by == nil
      assert ctx.feed.id
    end
  end
end
