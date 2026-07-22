defmodule Earss.ReaderTest do
  use Earss.DataCase

  alias Earss.Reader
  alias Earss.Feeds
  alias Earss.Repo
  alias Earss.Reader.Subscription
  alias Earss.Reader.EntryState

  setup do
    {:ok, user} = Reader.create_user("reader_#{System.unique_integer([:positive])}", "secret")
    %{user: user}
  end

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
    test "create list update delete", %{user: user} do
      assert {:ok, cat} = Reader.create_category(user, %{name: "News", position: 1})
      assert [%{name: "News"}] = Reader.list_categories(user)

      assert {:ok, cat} = Reader.update_category(cat, %{name: "Tech"})
      assert cat.name == "Tech"

      assert {:ok, _} = Reader.delete_category(cat)
      assert Reader.list_categories(user) == []
    end
  end

  describe "subscribe / unsubscribe" do
    test "subscribe by link creates feed and subscription", %{user: user} do
      link = "https://example.com/sub_#{System.unique_integer([:positive])}.xml"

      assert {:ok, sub} =
               Reader.subscribe(user, %{link: link, title: "My Feed", refresh: false})

      assert sub.user_id == user.id
      assert sub.feed.link == link
      assert sub.feed.title == "My Feed"
      assert is_nil(sub.feed.last_unsubscribed_at)
      assert sub.feed.next_fetch_at
    end

    test "subscribe by feed_id", %{user: user} do
      feed = create_feed!()

      assert {:ok, sub} = Reader.subscribe(user, %{feed_id: feed.id, refresh: false})
      assert sub.feed_id == feed.id
    end

    test "duplicate subscribe fails", %{user: user} do
      feed = create_feed!()
      assert {:ok, _} = Reader.subscribe(user, %{feed_id: feed.id, refresh: false})

      assert {:error, %Ecto.Changeset{}} =
               Reader.subscribe(user, %{feed_id: feed.id, refresh: false})
    end

    test "unsubscribe deletes states and marks zero-subscriber feed", %{user: user} do
      feed = create_feed!()
      entry = insert_entry!(feed)

      assert {:ok, _} = Reader.subscribe(user, %{feed_id: feed.id, refresh: false})
      assert {:ok, _} = Reader.mark_read(user, entry.id)
      assert Repo.get_by(EntryState, user_id: user.id, entry_id: entry.id)

      assert {:ok, _} = Reader.unsubscribe(user, feed.id)
      assert Reader.get_subscription(user, feed.id) == nil
      assert Repo.get_by(EntryState, user_id: user.id, entry_id: entry.id) == nil

      feed = Feeds.get_feed(feed.id)
      assert feed.last_unsubscribed_at
    end

    test "unsubscribe with remaining subscriber does not mark unsubscribed", %{user: user} do
      feed = create_feed!()
      {:ok, other} = Reader.create_user("other_#{System.unique_integer([:positive])}", "x")

      assert {:ok, _} = Reader.subscribe(user, %{feed_id: feed.id, refresh: false})
      assert {:ok, _} = Reader.subscribe(other, %{feed_id: feed.id, refresh: false})
      assert {:ok, _} = Reader.unsubscribe(user, feed.id)

      feed = Feeds.get_feed(feed.id)
      assert is_nil(feed.last_unsubscribed_at)
    end

    test "resubscribe clears last_unsubscribed_at", %{user: user} do
      feed = create_feed!()
      assert {:ok, _} = Reader.subscribe(user, %{feed_id: feed.id, refresh: false})
      assert {:ok, _} = Reader.unsubscribe(user, feed.id)
      assert Feeds.get_feed(feed.id).last_unsubscribed_at

      assert {:ok, _} = Reader.subscribe(user, %{feed_id: feed.id, refresh: false})
      assert is_nil(Feeds.get_feed(feed.id).last_unsubscribed_at)
    end

    test "hide subscription", %{user: user} do
      feed = create_feed!()
      {:ok, sub} = Reader.subscribe(user, %{feed_id: feed.id, refresh: false})
      assert {:ok, sub} = Reader.hide_subscription(sub)
      assert sub.is_hidden
      assert [_] = Reader.list_subscriptions(user)
      assert [] = Reader.list_subscriptions(user, include_hidden: false)
    end
  end

  describe "entry states" do
    setup %{user: user} do
      feed = create_feed!()
      entry = insert_entry!(feed)
      {:ok, _} = Reader.subscribe(user, %{feed_id: feed.id, refresh: false})
      %{feed: feed, entry: entry}
    end

    test "mark read and unread", %{user: user, entry: entry} do
      assert {:ok, state} = Reader.mark_read(user, entry.id)
      assert state.is_read
      assert state.read_at

      assert {:ok, state} = Reader.mark_unread(user, entry.id)
      assert state.is_read == false
      assert is_nil(state.read_at)
    end

    test "star preserves read flag", %{user: user, entry: entry} do
      assert {:ok, _} = Reader.mark_read(user, entry.id)
      assert {:ok, state} = Reader.set_star(user, entry.id, true)
      assert state.is_star
      assert state.is_read
      assert state.read_at
    end
  end

  describe "list_entries" do
    setup %{user: user} do
      feed = create_feed!()
      e1 = insert_entry!(feed, %{title: "A", published_at: ~U[2024-01-02 00:00:00Z]})
      e2 = insert_entry!(feed, %{title: "B", published_at: ~U[2024-01-03 00:00:00Z]})
      {:ok, _} = Reader.subscribe(user, %{feed_id: feed.id, refresh: false})
      %{feed: feed, e1: e1, e2: e2}
    end

    test "returns subscribed entries newest first as unread by default", %{
      user: user,
      e1: e1,
      e2: e2
    } do
      rows = Reader.list_entries(user)
      assert length(rows) == 2
      assert hd(rows).entry.id == e2.id
      assert hd(rows).is_read == false
      assert Enum.any?(rows, &(&1.entry.id == e1.id))
    end

    test "unread_only and starred_only filters", %{user: user, e1: e1, e2: e2} do
      assert {:ok, _} = Reader.mark_read(user, e2.id)
      assert {:ok, _} = Reader.set_star(user, e1.id, true)

      unread = Reader.list_entries(user, unread_only: true)
      assert Enum.map(unread, & &1.entry.id) == [e1.id]

      starred = Reader.list_entries(user, starred_only: true)
      assert Enum.map(starred, & &1.entry.id) == [e1.id]
    end

    test "category filter", %{user: user, feed: feed} do
      {:ok, cat} = Reader.create_category(user, %{name: "C"})
      sub = Reader.get_subscription(user, feed.id)
      assert {:ok, _} = Reader.update_subscription(sub, %{category_id: cat.id})

      assert length(Reader.list_entries(user, category_id: cat.id)) == 2
      assert Reader.list_entries(user, category_id: :none) == []
    end

    test "hidden subscription excluded by default", %{user: user, feed: feed} do
      sub = Reader.get_subscription(user, feed.id)
      assert {:ok, _} = Reader.hide_subscription(sub)
      assert Reader.list_entries(user) == []
      assert length(Reader.list_entries(user, include_hidden: true)) == 2
    end
  end

  describe "delete_user lifecycle" do
    test "marks feed unsubscribed when last subscriber deleted", %{user: user} do
      feed = create_feed!()
      assert {:ok, _} = Reader.subscribe(user, %{feed_id: feed.id, refresh: false})

      assert {:ok, _} = Reader.delete_user(user.username, "secret")
      feed = Feeds.get_feed(feed.id)
      assert feed.last_unsubscribed_at
      assert Repo.aggregate(Subscription, :count) == 0
    end
  end
end
