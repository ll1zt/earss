defmodule Earss.MCP.Tools.ReadingTest do
  @moduledoc """
  Tests for the query and read-state tools.

  These drive the real tools through the real facades. Assertions focus on
  the properties that make the surface usable for an agent: lists carry
  excerpts rather than whole bodies, state is inlined, and mutating tools
  are gated in read-only mode.
  """

  use Earss.DataCase, async: false

  alias Earss.Feeds
  alias Earss.MCP.Tools.Reading
  alias Earss.Reader
  alias Earss.Repo

  setup do
    previous = Application.get_env(:earss, :mcp)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:earss, :mcp, previous),
        else: Application.delete_env(:earss, :mcp)
    end)

    {:ok, feed} =
      Feeds.create_feed(%{link: "https://example.com/mcp-reading.xml", title: "MCP Reading"})

    {:ok, _sub} = Reader.subscribe(%{feed_id: feed.id, refresh: false})

    {:ok, %{entries: [a, b]}} =
      Feeds.upsert_entries(feed, [
        %{
          guid: "mcp-r-1",
          link: "https://example.com/mcp-r-1",
          title: "First article",
          content: "<p>" <> String.duplicate("alpha ", 200) <> "</p>"
        },
        %{
          guid: "mcp-r-2",
          link: "https://example.com/mcp-r-2",
          title: "Second article",
          summary: "A short summary."
        }
      ])

    %{feed: feed, entry_a: a, entry_b: b}
  end

  defp tool(name), do: Enum.find(Reading.tools(), &(&1.name == name))

  defp call(name, args \\ %{}), do: tool(name).handler.(args)

  describe "entry_list/1" do
    test "returns excerpts rather than full bodies", %{entry_a: a} do
      assert {:ok, result} = call("entry_list")

      [first | _] = Enum.filter(result.entries, &(&1.id == a.id))
      # 200 × "alpha " is 1200 characters; the default excerpt is 500.
      assert first.truncated == true
      assert String.length(first.excerpt) <= 501
      # Stored HTML is stripped: models read prose, not markup.
      refute first.excerpt =~ "<p>"
      refute first.excerpt =~ "</p>"
      assert first.excerpt =~ "alpha"
    end

    test "inlines read and starred state" do
      assert {:ok, result} = call("entry_list")

      for entry <- result.entries do
        assert is_boolean(entry.is_read)
        assert is_boolean(entry.is_starred)
      end
    end

    test "respects the unread_only filter", ctx do
      Reader.mark_read(ctx.entry_a.id)

      assert {:ok, unread} = call("entry_list", %{"unread_only" => true})
      refute Enum.any?(unread.entries, &(&1.id == ctx.entry_a.id))
      assert Enum.any?(unread.entries, &(&1.id == ctx.entry_b.id))

      assert {:ok, all} = call("entry_list")
      assert Enum.any?(all.entries, &(&1.id == ctx.entry_a.id))
    end

    test "respects the starred_only filter", ctx do
      Reader.set_star(ctx.entry_b.id, true)

      assert {:ok, starred} = call("entry_list", %{"starred_only" => true})
      assert [%{id: id}] = starred.entries
      assert id == ctx.entry_b.id
    end

    test "filters by feed", ctx do
      assert {:ok, result} = call("entry_list", %{"feed_id" => ctx.feed.id})
      assert length(result.entries) == 2

      assert {:ok, other} = call("entry_list", %{"feed_id" => ctx.feed.id + 999})
      assert other.entries == []
    end

    test "honours limit and clamps it", ctx do
      assert {:ok, result} = call("entry_list", %{"limit" => 1})
      assert length(result.entries) == 1

      # A ridiculous limit must be bounded, not passed to the query.
      assert {:ok, clamped} = call("entry_list", %{"limit" => 100_000})
      assert length(clamped.entries) == 2
      assert clamped.count == 2
      assert ctx.entry_a.id
    end
  end

  describe "entry_get/1" do
    test "returns the full body", ctx do
      assert {:ok, detail} = call("entry_get", %{"id" => ctx.entry_a.id})
      assert detail.title == "First article"
      assert String.length(detail.text) > 1000
    end

    test "prefers content over summary even when both are present", ctx do
      # The body is the longer text; an entry that carries both a short
      # summary and a full body must return the body, or entry_get truncates
      # the article to its own summary — which is what an ingested item
      # typically has.
      {:ok, feed} =
        Feeds.create_feed(%{link: "https://example.com/mcp-both.xml", title: "Both"})

      {:ok, %{entries: [entry]}} =
        Feeds.upsert_entries(feed, [
          %{
            guid: "both-1",
            link: "https://example.com/both-1",
            title: "Has both",
            summary: "Short summary.",
            content: "<p>#{String.duplicate("body ", 300)}</p>"
          }
        ])

      assert {:ok, detail} = call("entry_get", %{"id" => entry.id})
      assert String.length(detail.text) > 1000
      assert detail.text =~ "body body body"
      assert detail.summary == "Short summary."
    end

    test "falls back to summary when there is no content", ctx do
      {:ok, feed} =
        Feeds.create_feed(%{link: "https://example.com/mcp-sumonly.xml", title: "Sum"})

      {:ok, %{entries: [entry]}} =
        Feeds.upsert_entries(feed, [
          %{
            guid: "sum-1",
            link: "https://example.com/sum-1",
            title: "Summary only",
            summary: "Only a summary here."
          }
        ])

      assert {:ok, detail} = call("entry_get", %{"id" => entry.id})
      assert detail.text =~ "Only a summary here."
      assert ctx.entry_a.id
    end

    test "errors on an unknown id" do
      assert {:error, :not_found} = call("entry_get", %{"id" => 999_999})
    end

    test "errors on a malformed id" do
      assert {:error, :invalid_id} = call("entry_get", %{"id" => "abc"})
    end
  end

  describe "feed_list/1" do
    test "reports unread counts and feed health", ctx do
      assert {:ok, result} = call("feed_list")

      sub = Enum.find(result.subscriptions, &(&1.feed_id == ctx.feed.id))
      assert sub.title == "MCP Reading"
      assert sub.unread_count == 2
      assert sub.feed.link == ctx.feed.link
    end

    test "hides hidden subscriptions by default", ctx do
      sub = Reader.get_subscription(ctx.feed.id)
      Reader.hide_subscription(sub)

      assert {:ok, visible} = call("feed_list")
      refute Enum.any?(visible.subscriptions, &(&1.feed_id == ctx.feed.id))

      assert {:ok, all} = call("feed_list", %{"include_hidden" => true})
      assert Enum.any?(all.subscriptions, &(&1.feed_id == ctx.feed.id))
    end
  end

  describe "entry_search/1" do
    setup do
      {:ok, feed} =
        Feeds.create_feed(%{link: "https://example.com/mcp-search.xml", title: "Search Feed"})

      {:ok, _} =
        Feeds.upsert_entries(feed, [
          %{
            guid: "search-1",
            link: "https://example.com/search-1",
            title: "Elixir GenServer patterns",
            content: "A guide to OTP supervision trees and process design."
          },
          %{
            guid: "search-2",
            link: "https://example.com/search-2",
            title: "机器学习入门",
            content: "深度学习是机器学习的一个分支。"
          },
          %{
            guid: "search-3",
            link: "https://example.com/search-3",
            title: "Unrelated note",
            content: "Grocery list."
          }
        ])

      %{search_feed: feed}
    end

    test "matches title and body, English and Chinese", _ctx do
      assert {:ok, gs} = call("entry_search", %{"query" => "GenServer"})
      assert length(gs.entries) == 1
      assert hd(gs.entries).title == "Elixir GenServer patterns"

      # Substring within the body also matches (ILIKE path).
      assert {:ok, sup} = call("entry_search", %{"query" => "supervision"})
      assert length(sup.entries) == 1

      # Chinese: a two-character phrase within a longer title.
      assert {:ok, zh} = call("entry_search", %{"query" => "机器学习"})
      assert length(zh.entries) == 1
      assert hd(zh.entries).title == "机器学习入门"
    end

    test "reports the search mode and rank flag", _ctx do
      assert {:ok, result} = call("entry_search", %{"query" => "GenServer"})
      assert result.search_mode in [:pgroonga, :ilike]
      assert result.ranked == (result.search_mode == :pgroonga)
      assert result.query == "GenServer"
    end

    test "empty query yields no results, not an error", _ctx do
      assert {:ok, result} = call("entry_search", %{"query" => "   "})
      assert result.entries == []
    end

    test "returns excerpts, not full bodies", _ctx do
      assert {:ok, result} = call("entry_search", %{"query" => "supervision"})
      [first | _] = result.entries
      assert is_binary(first.excerpt)
      assert is_boolean(first.truncated)
    end

    # The ranked branch of entry_search is only reachable where PGroonga is
    # installed; on other hosts this still runs the ILIKE path. Asserting on
    # the mode keeps the test meaningful in both environments instead of
    # skipping.
    test "search results are self-consistent with the active mode", _ctx do
      assert {:ok, result} = call("entry_search", %{"query" => "机器学习"})

      assert result.search_mode in [:pgroonga, :ilike]
      assert result.ranked == (result.search_mode == :pgroonga)

      if result.search_mode == :pgroonga do
        assert Enum.all?(result.entries, &(&1.title == "机器学习入门"))
      end
    end
  end

  describe "read-state tools" do
    test "marks read and unread", ctx do
      assert {:ok, _} = call("entry_mark_read", %{"id" => ctx.entry_a.id})
      assert Repo.get_by(Earss.Reader.EntryState, entry_id: ctx.entry_a.id).is_read == true

      assert {:ok, _} = call("entry_mark_unread", %{"id" => ctx.entry_a.id})
      assert Repo.get_by(Earss.Reader.EntryState, entry_id: ctx.entry_a.id).is_read == false
    end

    test "stars and unstars", ctx do
      assert {:ok, _} = call("entry_star", %{"id" => ctx.entry_b.id})
      assert Repo.get_by(Earss.Reader.EntryState, entry_id: ctx.entry_b.id).is_star == true

      assert {:ok, _} = call("entry_unstar", %{"id" => ctx.entry_b.id})
      assert Repo.get_by(Earss.Reader.EntryState, entry_id: ctx.entry_b.id).is_star == false
    end

    test "errors on an unknown entry" do
      assert {:error, :not_found} = call("entry_mark_read", %{"id" => 999_999})
    end
  end

  describe "read-only mode" do
    test "mutating tools are marked mutating and read tools are not" do
      assert tool("entry_list").mutating == false
      assert tool("entry_get").mutating == false
      assert tool("feed_list").mutating == false

      assert tool("entry_mark_read").mutating == true
      assert tool("entry_star").mutating == true
    end

    test "the handler hides mutating tools from tools/list" do
      Application.put_env(:earss, :mcp, enabled: true, api_key: "k", read_only: true)

      {:ok, tools, _cursor, _state} = Earss.MCP.Handler.handle_list_tools(nil, %{})

      names = Enum.map(tools, & &1.name)
      assert "entry_list" in names
      assert "ping" in names
      refute "entry_mark_read" in names
      refute "entry_star" in names
    end

    test "the handler rejects calls to mutating tools" do
      Application.put_env(:earss, :mcp, enabled: true, api_key: "k", read_only: true)

      assert {:error, msg, _state} =
               Earss.MCP.Handler.handle_call_tool("entry_mark_read", %{"id" => 1}, %{})

      assert msg =~ "read-only"
    end
  end
end
