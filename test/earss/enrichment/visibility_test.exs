defmodule Earss.Enrichment.VisibilityTest do
  use Earss.DataCase

  alias Earss.Repo
  alias Earss.Feeds
  alias Earss.Feeds.{Entry, EntryTranslation}
  alias Earss.Reader
  alias Earss.Reader.{Subscription, User}
  alias Earss.GReader

  defp unique_link, do: "https://example.com/feed_#{System.unique_integer([:positive])}.xml"

  defp insert_feed!(attrs \\ %{}) do
    {:ok, feed} = Feeds.create_feed(Map.merge(%{link: unique_link()}, attrs))
    feed
  end

  defp insert_entry!(feed, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    defaults = %{
      feed_id: feed.id,
      link: "https://example.com/posts/#{n}",
      guid: "guid-#{n}",
      title: "Original title",
      content: "<p>Original body</p>",
      content_hash: "hash-#{n}"
    }

    %Entry{}
    |> Entry.changeset(Map.merge(defaults, Map.new(attrs)))
    |> Repo.insert!()
  end

  defp insert_user! do
    %User{}
    |> User.changeset(%{
      username: "vis_#{System.unique_integer([:positive])}",
      password_hash: "hash",
      user_type: "admin"
    })
    |> Repo.insert!()
  end

  defp subscribe!(user, feed, attrs \\ %{}) do
    %Subscription{}
    |> Subscription.changeset(Map.merge(%{user_id: user.id, feed_id: feed.id}, attrs))
    |> Repo.insert!()
  end

  defp insert_translation!(entry) do
    %EntryTranslation{}
    |> EntryTranslation.changeset(%{
      entry_id: entry.id,
      lang: "zh",
      title: "译题",
      content: "<p>译正文</p>",
      original_hash: entry.content_hash,
      model: "test",
      translated_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert!()
  end

  defp stream_items(user) do
    contents =
      GReader.stream_contents(user, "user/-/state/com.google/reading-list",
        n: 10,
        exclude_read: true
      )

    contents["items"]
  end

  test "hides pending new entries of a translated feed" do
    user = insert_user!()
    feed = insert_feed!(%{translate_to: "zh"})
    entry = insert_entry!(feed)
    subscribe!(user, feed)

    # ingest marks new entries pending; pending entries are hidden
    :ok = Earss.Enrichment.mark_pending(feed, [entry])
    assert stream_items(user) == []
  end

  test "shows the entry once a translation exists" do
    user = insert_user!()
    feed = insert_feed!(%{translate_to: "zh"})
    entry = insert_entry!(feed)
    subscribe!(user, feed)

    # ingest flow: mark pending, translate, pending cleared
    :ok = Earss.Enrichment.mark_pending(feed, [entry])
    insert_translation!(entry)
    :ok = Earss.Enrichment.clear_pending(feed)

    assert [item] = stream_items(user)
    assert item["title"] == "译题"
  end

  test "shows the original once the pending flag is cleared (translation disabled)" do
    user = insert_user!()
    feed = insert_feed!(%{translate_to: "zh"})
    entry = insert_entry!(feed)
    subscribe!(user, feed)

    # entry is pending → hidden
    :ok = Earss.Enrichment.mark_pending(feed, [entry])
    assert stream_items(user) == []

    # disabling translation clears pending → original visible
    {:ok, feed} = Feeds.update_feed(feed, %{translate_to: nil})
    :ok = Earss.Enrichment.clear_pending(feed)

    assert [item] = stream_items(user)
    assert item["title"] == "Original title"
  end

  test "a subscription override alone triggers hiding" do
    user = insert_user!()
    feed = insert_feed!()
    entry = insert_entry!(feed)
    subscribe!(user, feed, %{translate_to: "zh"})

    :ok = Earss.Enrichment.mark_pending(feed, [entry])
    assert stream_items(user) == []
  end

  test "feeds without a translation config are unaffected" do
    user = insert_user!()
    feed = insert_feed!()
    insert_entry!(feed)
    subscribe!(user, feed)

    assert [item] = stream_items(user)
    assert item["title"] == "Original title"
  end

  test "unread counts exclude pending entries" do
    user = insert_user!()
    feed = insert_feed!(%{translate_to: "zh"})
    entry = insert_entry!(feed)
    subscribe!(user, feed)
    :ok = Earss.Enrichment.mark_pending(feed, [entry])

    assert Reader.unread_counts_by_feed(user) == %{}
  end

  test "fever items exclude pending entries" do
    user = insert_user!()
    feed = insert_feed!(%{translate_to: "zh"})
    entry = insert_entry!(feed)
    subscribe!(user, feed)
    :ok = Earss.Enrichment.mark_pending(feed, [entry])

    assert Reader.list_fever_items(user, limit: 50) == []
  end

  test "json timeline excludes pending entries" do
    user = insert_user!()
    feed = insert_feed!(%{translate_to: "zh"})
    entry = insert_entry!(feed)
    subscribe!(user, feed)
    :ok = Earss.Enrichment.mark_pending(feed, [entry])

    assert Reader.list_entries(user, limit: 50) == []
  end
end
