defmodule Earss.ReaderTest do
  use Earss.DataCase

  alias Earss.Reader
  alias Earss.Feeds
  alias Earss.Repo
  alias Earss.Reader.Subscription
  alias Earss.Reader.EntryState

  defp create_feed!(attrs \\ %{}) do
    link =
      Map.get(attrs, :link, "https://example.com/f_#{System.unique_integer([:positive])}.xml")

    {:ok, feed} =
      Feeds.create_feed(
        Map.merge(%{link: link, title: "Feed"}, Map.delete(attrs, :link))
        |> Map.put(:link, link)
      )

    feed
  end

  defp insert_entry!(feed, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, entry} =
      Feeds.upsert_entry(
        feed,
        Map.merge(
          %{
            link: "https://example.com/p/#{n}",
            guid: "g-#{n}",
            title: "Post #{n}",
            published_at: DateTime.utc_now() |> DateTime.truncate(:second)
          },
          attrs
        )
      )

    entry
  end

  describe "categories" do
    test "create list update delete" do
      assert {:ok, cat} = Reader.create_category(%{name: "News", position: 1})
      assert [%{name: "News"}] = Reader.list_categories()

      assert {:ok, cat} = Reader.update_category(cat, %{name: "Tech"})
      assert cat.name == "Tech"

      assert {:ok, _} = Reader.delete_category(cat)
      assert Reader.list_categories() == []
    end
  end

  describe "subscribe / unsubscribe" do
    test "subscribe by link creates feed and subscription" do
      link = "https://example.com/sub_#{System.unique_integer([:positive])}.xml"

      assert {:ok, sub} =
               Reader.subscribe(%{link: link, title: "My Feed", refresh: false})

      assert sub.feed.link == link
      assert sub.feed.title == "My Feed"
      assert is_nil(sub.feed.last_unsubscribed_at)
      assert sub.feed.next_fetch_at
    end

    test "subscribe by feed_id" do
      feed = create_feed!()

      assert {:ok, sub} = Reader.subscribe(%{feed_id: feed.id, refresh: false})
      assert sub.feed_id == feed.id
    end

    test "duplicate subscribe fails" do
      feed = create_feed!()
      assert {:ok, _} = Reader.subscribe(%{feed_id: feed.id, refresh: false})

      assert {:error, %Ecto.Changeset{}} =
               Reader.subscribe(%{feed_id: feed.id, refresh: false})
    end

    test "unsubscribe deletes states and marks zero-subscriber feed" do
      feed = create_feed!()
      entry = insert_entry!(feed)

      assert {:ok, _} = Reader.subscribe(%{feed_id: feed.id, refresh: false})
      assert {:ok, _} = Reader.mark_read(entry.id)
      assert Repo.get_by(EntryState, entry_id: entry.id)

      assert {:ok, _} = Reader.unsubscribe(feed.id)
      assert Reader.get_subscription(feed.id) == nil
      assert Repo.get_by(EntryState, entry_id: entry.id) == nil

      feed = Feeds.get_feed(feed.id)
      assert feed.last_unsubscribed_at
    end

    test "resubscribe clears last_unsubscribed_at" do
      feed = create_feed!()
      assert {:ok, _} = Reader.subscribe(%{feed_id: feed.id, refresh: false})
      assert {:ok, _} = Reader.unsubscribe(feed.id)
      assert Feeds.get_feed(feed.id).last_unsubscribed_at

      assert {:ok, _} = Reader.subscribe(%{feed_id: feed.id, refresh: false})
      assert is_nil(Feeds.get_feed(feed.id).last_unsubscribed_at)
    end

    test "hide subscription" do
      feed = create_feed!()
      {:ok, sub} = Reader.subscribe(%{feed_id: feed.id, refresh: false})
      assert {:ok, sub} = Reader.hide_subscription(sub)
      assert sub.is_hidden
      assert [_] = Reader.list_subscriptions()
      assert [] = Reader.list_subscriptions(include_hidden: false)
    end
  end

  describe "entry states" do
    setup do
      feed = create_feed!()
      entry = insert_entry!(feed)
      {:ok, _} = Reader.subscribe(%{feed_id: feed.id, refresh: false})
      %{feed: feed, entry: entry}
    end

    test "mark read and unread", %{entry: entry} do
      assert {:ok, state} = Reader.mark_read(entry.id)
      assert state.is_read
      assert state.read_at

      assert {:ok, state} = Reader.mark_unread(entry.id)
      assert state.is_read == false
      assert is_nil(state.read_at)
    end

    test "star preserves read flag", %{entry: entry} do
      assert {:ok, _} = Reader.mark_read(entry.id)
      assert {:ok, state} = Reader.set_star(entry.id, true)
      assert state.is_star
      assert state.is_read
      assert state.read_at
    end
  end

  describe "list_entries" do
    setup do
      feed = create_feed!()
      e1 = insert_entry!(feed, %{title: "A", published_at: ~U[2024-01-02 00:00:00Z]})
      e2 = insert_entry!(feed, %{title: "B", published_at: ~U[2024-01-03 00:00:00Z]})
      {:ok, _} = Reader.subscribe(%{feed_id: feed.id, refresh: false})
      %{feed: feed, e1: e1, e2: e2}
    end

    test "returns subscribed entries newest first as unread by default", %{e1: e1, e2: e2} do
      rows = Reader.list_entries()
      assert length(rows) == 2
      assert hd(rows).entry.id == e2.id
      assert hd(rows).is_read == false
      assert Enum.any?(rows, &(&1.entry.id == e1.id))
    end

    test "unread_only and starred_only filters", %{e1: e1, e2: e2} do
      assert {:ok, _} = Reader.mark_read(e2.id)
      assert {:ok, _} = Reader.set_star(e1.id, true)

      unread = Reader.list_entries(unread_only: true)
      assert Enum.map(unread, & &1.entry.id) == [e1.id]

      starred = Reader.list_entries(starred_only: true)
      assert Enum.map(starred, & &1.entry.id) == [e1.id]
    end

    test "category filter", %{feed: feed} do
      {:ok, cat} = Reader.create_category(%{name: "C"})
      sub = Reader.get_subscription(feed.id)
      assert {:ok, _} = Reader.update_subscription(sub, %{category_id: cat.id})

      assert length(Reader.list_entries(category_id: cat.id)) == 2
      assert Reader.list_entries(category_id: :none) == []
    end

    test "hidden subscription excluded by default", %{feed: feed} do
      sub = Reader.get_subscription(feed.id)
      assert {:ok, _} = Reader.hide_subscription(sub)
      assert Reader.list_entries() == []
      assert length(Reader.list_entries(include_hidden: true)) == 2
    end
  end
end
