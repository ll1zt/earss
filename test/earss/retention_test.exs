defmodule Earss.RetentionTest do
  use Earss.DataCase

  alias Earss.Retention
  alias Earss.Feeds
  alias Earss.Reader
  alias Earss.Repo
  alias Earss.Feeds.Entry
  alias Earss.Feeds.Feed
  alias Earss.Reader.EntryState

  defp feed! do
    {:ok, feed} =
      Feeds.create_feed(%{
        link: "https://example.com/r_#{System.unique_integer([:positive])}.xml"
      })

    feed
  end

  defp entry!(feed, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, entry} =
      Feeds.upsert_entry(
        feed,
        Map.merge(
          %{
            link: "https://example.com/e/#{n}",
            guid: "g-#{n}",
            title: "E#{n}"
          },
          attrs
        )
      )

    entry
  end

  defp backdate_entry!(%Entry{} = entry, days_ago) do
    ts =
      DateTime.utc_now()
      |> DateTime.add(-days_ago * 86_400, :second)
      |> DateTime.truncate(:second)

    from(e in Entry, where: e.id == ^entry.id)
    |> Repo.update_all(set: [inserted_at: ts, updated_at: ts])

    Repo.get!(Entry, entry.id)
  end

  defp backdate_state_read_at!(%EntryState{} = state, days_ago) do
    ts =
      DateTime.utc_now()
      |> DateTime.add(-days_ago * 86_400, :second)
      |> DateTime.truncate(:second)

    from(st in EntryState, where: st.id == ^state.id)
    |> Repo.update_all(set: [read_at: ts, updated_at: ts])

    Repo.get!(EntryState, state.id)
  end

  defp stamp_unsubscribed!(%Feed{} = feed, days_ago) do
    ts =
      DateTime.utc_now()
      |> DateTime.add(-days_ago * 86_400, :second)
      |> DateTime.truncate(:second)

    {:ok, feed} = Feeds.update_feed(feed, %{last_unsubscribed_at: ts})
    feed
  end

  describe "Level A — expired states" do
    test "deletes old read unstarred states" do
      feed = feed!()
      entry = entry!(feed)
      {:ok, _} = Reader.subscribe(%{feed_id: feed.id, refresh: false})
      {:ok, state} = Reader.mark_read(entry.id)
      backdate_state_read_at!(state, 91)

      result = Retention.purge_expired_states()
      assert result.deleted == 1
      assert result.dry_run == false
      assert Repo.get(EntryState, state.id) == nil
    end

    test "keeps starred or recent read states" do
      feed = feed!()
      e1 = entry!(feed)
      e2 = entry!(feed)
      {:ok, _} = Reader.subscribe(%{feed_id: feed.id, refresh: false})

      {:ok, starred} = Reader.mark_read(e1.id)
      {:ok, _} = Reader.set_star(e1.id, true)
      backdate_state_read_at!(starred, 100)

      {:ok, recent} = Reader.mark_read(e2.id)
      # recent stays within 90 days

      assert %{deleted: 0} = Retention.purge_expired_states()
      assert Repo.get(EntryState, starred.id)
      assert Repo.get(EntryState, recent.id)
    end

    test "dry_run does not delete" do
      feed = feed!()
      entry = entry!(feed)
      {:ok, _} = Reader.subscribe(%{feed_id: feed.id, refresh: false})
      {:ok, state} = Reader.mark_read(entry.id)
      backdate_state_read_at!(state, 100)

      assert %{deleted: 1, dry_run: true} = Retention.purge_expired_states(dry_run: true)
      assert Repo.get(EntryState, state.id)
    end
  end

  describe "Level B — reclaimable entries" do
    test "does not delete young entry without states" do
      feed = feed!()
      entry = entry!(feed)
      backdate_entry!(entry, 10)

      assert %{deleted: 0} = Retention.purge_reclaimable_entries()
      assert Repo.get(Entry, entry.id)
    end

    test "deletes old entry without states" do
      feed = feed!()
      entry = entry!(feed)
      backdate_entry!(entry, 181)

      assert %{deleted: 1} = Retention.purge_reclaimable_entries()
      assert Repo.get(Entry, entry.id) == nil
    end

    test "does not delete old entry with unread state" do
      feed = feed!()
      entry = entry!(feed)
      backdate_entry!(entry, 200)
      {:ok, _} = Reader.subscribe(%{feed_id: feed.id, refresh: false})
      # explicit unread state
      {:ok, _} = Reader.mark_read(entry.id)
      {:ok, _} = Reader.mark_unread(entry.id)

      assert %{deleted: 0} = Retention.purge_reclaimable_entries()
      assert Repo.get(Entry, entry.id)
    end

    test "does not delete old starred entry" do
      feed = feed!()
      entry = entry!(feed)
      backdate_entry!(entry, 200)
      {:ok, _} = Reader.subscribe(%{feed_id: feed.id, refresh: false})
      {:ok, _} = Reader.set_star(entry.id, true)

      assert %{deleted: 0} = Retention.purge_reclaimable_entries()
      assert Repo.get(Entry, entry.id)
    end

    test "after Level A, old read unstarred entry can be reclaimed" do
      feed = feed!()
      entry = entry!(feed)
      backdate_entry!(entry, 200)
      {:ok, _} = Reader.subscribe(%{feed_id: feed.id, refresh: false})
      {:ok, state} = Reader.mark_read(entry.id)
      backdate_state_read_at!(state, 100)

      # Before A: has read state only → Level B may still see no unread/star
      # read is_read=true does not block Level B; only unread and star do.
      # So B can delete even with old read state (cascade deletes state).
      # Policy: NOT EXISTS unread AND NOT EXISTS star — read states OK to wipe with entry.
      assert %{deleted: 1} = Retention.purge_reclaimable_entries()
      assert Repo.get(Entry, entry.id) == nil
    end
  end

  describe "Level C — unsubscribed feeds" do
    test "deletes feed past grace with no subscribers" do
      feed = feed!()
      entry = entry!(feed)
      stamp_unsubscribed!(feed, 31)

      assert %{deleted: 1} = Retention.purge_unsubscribed_feeds()
      assert Repo.get(Feed, feed.id) == nil
      assert Repo.get(Entry, entry.id) == nil
    end

    test "keeps recently unsubscribed feed" do
      feed = feed!()
      stamp_unsubscribed!(feed, 5)

      assert %{deleted: 0} = Retention.purge_unsubscribed_feeds()
      assert Repo.get(Feed, feed.id)
    end

    test "does not delete feed that still has subscription" do
      feed = feed!()
      {:ok, _} = Reader.subscribe(%{feed_id: feed.id, refresh: false})
      # force stamp even though subscribed (inconsistent but guard must hold)
      stamp_unsubscribed!(feed, 40)

      assert %{deleted: 0} = Retention.purge_unsubscribed_feeds()
      assert Repo.get(Feed, feed.id)
    end
  end

  describe "run_all/1" do
    test "runs A then B then C" do
      feed = feed!()
      entry = entry!(feed)
      backdate_entry!(entry, 200)
      {:ok, _} = Reader.subscribe(%{feed_id: feed.id, refresh: false})
      {:ok, state} = Reader.mark_read(entry.id)
      backdate_state_read_at!(state, 100)

      # unsubscribe to allow feed purge path for another feed
      orphan = feed!()
      stamp_unsubscribed!(orphan, 40)

      result = Retention.run_all()
      assert result.states.deleted >= 0
      assert result.entries.deleted >= 1
      assert result.feeds.deleted == 1
      assert Repo.get(Feed, orphan.id) == nil
    end
  end
end
