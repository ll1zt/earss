defmodule Earss.ReaderExtraTest do
  use Earss.DataCase

  alias Earss.Reader
  alias Earss.Feeds

  test "unread_counts_by_feed and mark_entries_read" do
    {:ok, feed} =
      Feeds.create_feed(%{
        link: "https://example.com/uc_#{System.unique_integer([:positive])}.xml"
      })

    {:ok, e1} =
      Feeds.upsert_entry(feed, %{
        link: "https://example.com/1",
        guid: "1",
        title: "1"
      })

    {:ok, e2} =
      Feeds.upsert_entry(feed, %{
        link: "https://example.com/2",
        guid: "2",
        title: "2"
      })

    {:ok, _} = Reader.subscribe(%{feed_id: feed.id, refresh: false})

    counts = Reader.unread_counts_by_feed()
    assert counts[feed.id] == 2

    [sub] = Reader.list_subscriptions(with_unread_count: true)
    assert sub.unread_count == 2

    assert {:ok, %{marked: 1}} = Reader.mark_entries_read(ids: [e1.id])
    assert Reader.unread_counts_by_feed()[feed.id] == 1

    assert {:ok, %{marked: 2}} = Reader.mark_entries_read(feed_id: feed.id)
    assert Map.get(Reader.unread_counts_by_feed(), feed.id, 0) == 0
    assert Reader.get_entry_state(e2.id).is_read
  end
end
