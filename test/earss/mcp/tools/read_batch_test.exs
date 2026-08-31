defmodule Earss.MCP.Tools.ReadBatchTest do
  @moduledoc """
  Tests for entry_mark_read_batch: the three selection dimensions (ids,
  feed, category), the optional `before` time filter, and the not-found path.
  """

  use Earss.DataCase, async: false

  alias Earss.Feeds
  alias Earss.MCP.Tools.ReadBatch
  alias Earss.Reader
  alias Earss.Repo

  setup do
    {:ok, feed} = Feeds.create_feed(%{link: "https://example.com/mcp-batch.xml", title: "Batch"})

    {:ok, cat} = Reader.create_category(%{name: "Tech"})
    {:ok, _} = Reader.subscribe(%{feed_id: feed.id, category_id: cat.id, refresh: false})

    {:ok, %{entries: [a, b, c]}} =
      Feeds.upsert_entries(feed, [
        %{
          guid: "b-1",
          link: "https://e.com/b-1",
          title: "Old",
          published_at: iso("2026-01-01T00:00:00Z")
        },
        %{
          guid: "b-2",
          link: "https://e.com/b-2",
          title: "Recent",
          published_at: iso("2026-08-01T00:00:00Z")
        },
        %{
          guid: "b-3",
          link: "https://e.com/b-3",
          title: "Also recent",
          published_at: iso("2026-08-15T00:00:00Z")
        }
      ])

    %{feed: feed, category: cat, a: a, b: b, c: c}
  end

  defp iso(s) do
    {:ok, dt, _} = DateTime.from_iso8601(s)
    dt
  end

  defp tool, do: Enum.find(ReadBatch.tools(), &(&1.name == "entry_mark_read_batch"))

  defp call(args \\ %{}), do: tool().handler.(args)

  defp read?(entry_id) do
    case Repo.get_by(Earss.Reader.EntryState, entry_id: entry_id) do
      nil -> false
      state -> state.is_read
    end
  end

  describe "entry_mark_read_batch/1" do
    test "marks explicit ids", %{a: a, b: b, c: c} do
      assert {:ok, result} = call(%{"ids" => [a.id, b.id]})

      assert result.marked == 2
      assert result.scope.type == :ids
      assert read?(a.id)
      assert read?(b.id)
      refute read?(c.id)
    end

    test "marks every entry of a feed", %{feed: feed, a: a, c: c} do
      assert {:ok, result} = call(%{"feed_id" => feed.id})

      assert result.marked == 3
      assert read?(a.id)
      assert read?(c.id)
    end

    test "marks every entry of a category", %{category: cat, a: a, b: b} do
      assert {:ok, result} = call(%{"category_id" => cat.id})

      assert result.marked == 3
      assert read?(a.id)
      assert read?(b.id)
    end

    test "respects the before timestamp", %{feed: feed, a: a, b: b, c: c} do
      assert {:ok, result} =
               call(%{"feed_id" => feed.id, "before" => "2026-06-01T00:00:00Z"})

      assert result.marked == 1
      assert read?(a.id)
      refute read?(b.id)
      refute read?(c.id)
    end

    test "errors when the feed has no subscription" do
      assert {:error, msg} = call(%{"feed_id" => 999_999})
      assert msg =~ "no subscription"
    end

    test "requires one selector" do
      assert {:ok, result} = call(%{})
      assert result.marked == 0
    end

    test "is mutating" do
      assert tool().mutating == true
      assert tool().destructive == false
    end
  end
end
