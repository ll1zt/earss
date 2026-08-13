defmodule Earss.FeedsTest do
  use Earss.DataCase

  alias Earss.Repo
  alias Earss.Feeds
  alias Earss.Feeds.Entry

  defp unique_link do
    "https://example.com/feed_#{System.unique_integer([:positive])}.xml"
  end

  describe "create_feed/1" do
    test "creates a feed with refresh defaults from config" do
      link = unique_link()

      assert {:ok, feed} = Feeds.create_feed(%{link: link, title: "Example"})
      assert feed.link == link
      assert feed.title == "Example"
      assert feed.refresh_interval == 30
      assert feed.min_refresh_interval == 15
      assert feed.max_refresh_interval == 10_080
      assert feed.feed_type == "rss"
      assert feed.is_active == true
    end

    test "trims link and rejects duplicates" do
      link = unique_link()

      assert {:ok, _} = Feeds.create_feed(%{link: "  #{link}  "})
      assert {:error, changeset} = Feeds.create_feed(%{link: link})
      assert %{link: _} = errors_on(changeset)
    end

    test "allows overriding interval fields" do
      assert {:ok, feed} =
               Feeds.create_feed(%{
                 link: unique_link(),
                 refresh_interval: 60,
                 min_refresh_interval: 30,
                 max_refresh_interval: 120
               })

      assert feed.refresh_interval == 60
      assert feed.min_refresh_interval == 30
      assert feed.max_refresh_interval == 120
    end

    test "requires link" do
      assert {:error, changeset} = Feeds.create_feed(%{title: "No link"})
      assert %{link: _} = errors_on(changeset)
    end
  end

  describe "get_feed/1 and get_feed_by_link/1" do
    test "fetches by id and link" do
      {:ok, feed} = Feeds.create_feed(%{link: unique_link()})

      assert Feeds.get_feed(feed.id).id == feed.id
      assert Feeds.get_feed_by_link(feed.link).id == feed.id
      assert Feeds.get_feed_by_link("  #{feed.link}  ").id == feed.id
      assert Feeds.get_feed(-1) == nil
      assert Feeds.get_feed_by_link("https://missing.example/feed.xml") == nil
    end
  end

  describe "ensure_feed/2" do
    test "creates when missing and returns existing without updating" do
      link = unique_link()

      assert {:ok, feed1} = Feeds.ensure_feed(link, %{title: "First"})
      assert feed1.title == "First"

      assert {:ok, feed2} = Feeds.ensure_feed(link, %{title: "Second"})
      assert feed2.id == feed1.id
      assert feed2.title == "First"
    end
  end

  describe "update_feed/2" do
    test "updates mutable fields" do
      {:ok, feed} = Feeds.create_feed(%{link: unique_link(), title: "Old"})
      assert {:ok, updated} = Feeds.update_feed(feed, %{title: "New", is_active: false})
      assert updated.title == "New"
      assert updated.is_active == false
    end
  end

  describe "upsert_entry/2" do
    setup do
      {:ok, feed} = Feeds.create_feed(%{link: unique_link()})
      %{feed: feed}
    end

    test "inserts a new entry", %{feed: feed} do
      assert {:ok, entry} =
               Feeds.upsert_entry(feed, %{
                 link: "https://example.com/a",
                 guid: "g-a",
                 title: "A"
               })

      assert entry.feed_id == feed.id
      assert entry.guid == "g-a"
      assert entry.title == "A"
    end

    test "updates content on same feed_id + guid", %{feed: feed} do
      assert {:ok, first} =
               Feeds.upsert_entry(feed, %{
                 link: "https://example.com/a",
                 guid: "g-a",
                 title: "Old title",
                 content: "v1"
               })

      assert {:ok, second} =
               Feeds.upsert_entry(feed, %{
                 link: "https://example.com/a-updated",
                 guid: "g-a",
                 title: "New title",
                 content: "v2",
                 content_hash: "hash2"
               })

      assert second.id == first.id
      assert second.title == "New title"
      assert second.content == "v2"
      assert second.link == "https://example.com/a-updated"
      assert second.content_hash == "hash2"
      assert Repo.aggregate(Entry, :count) == 1
    end

    test "falls back empty guid to link", %{feed: feed} do
      assert {:ok, entry} =
               Feeds.upsert_entry(feed, %{
                 link: "https://example.com/no-guid",
                 guid: "  ",
                 title: "X"
               })

      assert entry.guid == "https://example.com/no-guid"
    end

    test "rejects entries without link or guid", %{feed: feed} do
      assert {:error, :invalid_entry} = Feeds.upsert_entry(feed, %{title: "Nope"})
      assert {:error, :invalid_entry} = Feeds.upsert_entry(feed, %{link: "", guid: ""})
    end

    test "trims guid and link", %{feed: feed} do
      assert {:ok, entry} =
               Feeds.upsert_entry(feed, %{
                 link: "  https://example.com/t  ",
                 guid: "  g-t  ",
                 title: "T"
               })

      assert entry.link == "https://example.com/t"
      assert entry.guid == "g-t"
    end
  end

  describe "upsert_entries/2" do
    setup do
      {:ok, feed} = Feeds.create_feed(%{link: unique_link()})
      %{feed: feed}
    end

    test "batch upserts and skips invalid rows", %{feed: feed} do
      assert {:ok, %{entries: entries, skipped: skipped}} =
               Feeds.upsert_entries(feed, [
                 %{link: "https://example.com/1", guid: "1", title: "One"},
                 %{title: "bad"},
                 %{link: "https://example.com/2", guid: "2", title: "Two"}
               ])

      assert length(entries) == 2
      assert skipped == 1
      assert Repo.aggregate(from(e in Entry, where: e.feed_id == ^feed.id), :count) == 2
    end

    test "updates existing guids in batch", %{feed: feed} do
      assert {:ok, _} =
               Feeds.upsert_entries(feed, [
                 %{link: "https://example.com/1", guid: "1", title: "One"}
               ])

      assert {:ok, %{entries: [entry]}} =
               Feeds.upsert_entries(feed, [
                 %{link: "https://example.com/1", guid: "1", title: "One updated"}
               ])

      assert entry.title == "One updated"
      assert Repo.aggregate(Entry, :count) == 1
    end

    test "skips entries whose content_hash is unchanged (D4)", %{feed: feed} do
      assert {:ok, %{entries: [entry]}} =
               Feeds.upsert_entries(feed, [
                 %{link: "https://example.com/1", guid: "1", title: "One", content: "v1"}
               ])

      updated_at = entry.updated_at

      assert {:ok, %{entries: [], skipped: 1}} =
               Feeds.upsert_entries(feed, [
                 %{link: "https://example.com/1", guid: "1", title: "One", content: "v1"}
               ])

      assert Repo.get!(Entry, entry.id).updated_at == updated_at
    end

    test "computes a content_hash when the adapter provides none", %{feed: feed} do
      assert {:ok, %{entries: [entry]}} =
               Feeds.upsert_entries(feed, [
                 %{link: "https://example.com/1", guid: "1", title: "One", content: "v1"}
               ])

      assert is_binary(entry.content_hash) and entry.content_hash != ""

      # changing any mutable field changes the hash → re-upserted
      assert {:ok, %{entries: [updated]}} =
               Feeds.upsert_entries(feed, [
                 %{link: "https://example.com/1", guid: "1", title: "One", content: "v2"}
               ])

      assert updated.content_hash != entry.content_hash
    end
  end

  describe "list_entries/2" do
    test "orders by published_at desc and respects limit" do
      {:ok, feed} = Feeds.create_feed(%{link: unique_link()})
      t1 = ~U[2026-01-01 00:00:00Z]
      t2 = ~U[2026-02-01 00:00:00Z]

      {:ok, _} =
        Feeds.upsert_entry(feed, %{
          link: "https://example.com/old",
          guid: "old",
          published_at: t1,
          title: "Old"
        })

      {:ok, _} =
        Feeds.upsert_entry(feed, %{
          link: "https://example.com/new",
          guid: "new",
          published_at: t2,
          title: "New"
        })

      [first | _] = Feeds.list_entries(feed)
      assert first.guid == "new"

      assert length(Feeds.list_entries(feed, limit: 1)) == 1
    end
  end
end
