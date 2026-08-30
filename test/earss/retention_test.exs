defmodule Earss.RetentionTest do
  # async: false — the D/E tests swap global application env (:retention, :tts).
  use Earss.DataCase, async: false

  alias Earss.Retention
  alias Earss.Feeds
  alias Earss.Reader
  alias Earss.Repo
  alias Earss.TTS
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

  # —— Levels D + E: TTS requests and audio files ———

  describe "Level D — expired tts requests" do
    setup do
      dir = System.tmp_dir!() |> Path.join("earss-retention-tts-test")
      File.rm_rf!(dir)
      File.mkdir_p!(dir)

      prev = Application.get_env(:earss, :retention)
      prev_tts = Application.get_env(:earss, :tts)

      Application.put_env(:earss, :tts, Keyword.put(prev_tts || [], :audio_dir, dir))

      on_exit(fn ->
        File.rm_rf!(dir)
        restore_env(:earss, :retention, prev)
        restore_env(:earss, :tts, prev_tts)
      end)

      %{audio_dir: dir}
    end

    test "deletes expired ready rows and their audio files", %{audio_dir: dir} do
      %{request: request} = ready_request!(dir, "1.mp3")
      backdate_request!(request, 100)
      put_retention_config(tts_audio_days: 90)

      assert %{deleted: 1, dry_run: false} = Retention.purge_expired_tts_requests()

      assert Repo.get(TTS.Request, request.id) == nil
      refute File.exists?(Path.join(dir, "1.mp3"))
    end

    test "keeps rows younger than the window and non-ready states", %{audio_dir: dir} do
      %{request: fresh} = ready_request!(dir, "2.mp3")
      %{request: failed} = ready_request!(dir, "3.mp3")

      request_row!(failed.entry_id, state: :failed, audio_path: nil)
      backdate_request!(fresh, 10)
      backdate_request!(Repo.get!(TTS.Request, failed.id), 100)
      put_retention_config(tts_audio_days: 90)

      assert %{deleted: 0} = Retention.purge_expired_tts_requests()
      assert Repo.get(TTS.Request, fresh.id)
      assert Repo.get(TTS.Request, failed.id)
      assert File.exists?(Path.join(dir, "2.mp3"))
    end

    test "dry_run counts but deletes nothing", %{audio_dir: dir} do
      %{request: request} = ready_request!(dir, "4.mp3")
      backdate_request!(request, 100)
      put_retention_config(tts_audio_days: 90)

      assert %{deleted: 1, dry_run: true} = Retention.purge_expired_tts_requests(dry_run: true)

      assert Repo.get(TTS.Request, request.id)
      assert File.exists?(Path.join(dir, "4.mp3"))
    end

    test "disabled when tts_audio_days is nil", %{audio_dir: dir} do
      %{request: request} = ready_request!(dir, "5.mp3")
      backdate_request!(request, 400)
      put_retention_config(tts_audio_days: nil)

      assert %{deleted: 0} = Retention.purge_expired_tts_requests()
      assert Repo.get(TTS.Request, request.id)
    end
  end

  describe "Level E — orphaned audio files" do
    setup do
      dir = System.tmp_dir!() |> Path.join("earss-retention-tts-test")
      File.rm_rf!(dir)
      File.mkdir_p!(dir)

      prev = Application.get_env(:earss, :tts)
      Application.put_env(:earss, :tts, Keyword.put(prev || [], :audio_dir, dir))

      on_exit(fn ->
        File.rm_rf!(dir)
        restore_env(:earss, :tts, prev)
      end)

      %{audio_dir: dir}
    end

    test "sweeps files with no live row past the grace window", %{audio_dir: dir} do
      %{request: request} = ready_request!(dir, "10.mp3")
      File.write!(Path.join(dir, "999.mp3"), "orphan")
      backdate_file!(Path.join(dir, "999.mp3"), hours_ago: 48)

      assert %{deleted: 1, dry_run: false} = Retention.purge_orphan_audio_files()

      assert File.exists?(Path.join(dir, "10.mp3"))
      refute File.exists?(Path.join(dir, "999.mp3"))
      assert Repo.get(TTS.Request, request.id)
    end

    test "keeps recent orphans (worker may still be writing) and unknown files", %{
      audio_dir: dir
    } do
      ready_request!(dir, "11.mp3")
      File.write!(Path.join(dir, "998.mp3"), "fresh orphan")
      File.write!(Path.join(dir, "notes.txt"), "not ours")

      assert %{deleted: 0} = Retention.purge_orphan_audio_files()

      assert File.exists?(Path.join(dir, "11.mp3"))
      assert File.exists?(Path.join(dir, "998.mp3"))
      assert File.exists?(Path.join(dir, "notes.txt"))
    end

    test "cascade-orphans from entry deletion are swept", %{audio_dir: dir} do
      %{request: request} = ready_request!(dir, "12.mp3")
      Repo.delete!(request)
      backdate_file!(Path.join(dir, "12.mp3"), hours_ago: 48)

      assert %{deleted: 1} = Retention.purge_orphan_audio_files()
      refute File.exists?(Path.join(dir, "12.mp3"))
    end

    test "no-ops when audio_dir is unset" do
      prev = Application.get_env(:earss, :tts)
      Application.put_env(:earss, :tts, Keyword.delete(prev || [], :audio_dir))

      on_exit(fn -> restore_env(:earss, :tts, prev) end)

      assert %{deleted: 0} = Retention.purge_orphan_audio_files()
    end
  end

  describe "run_all result shape" do
    test "includes the tts levels" do
      result = Retention.run_all()

      assert %{deleted: n1, dry_run: _} = result.tts_requests
      assert %{deleted: n2, dry_run: _} = result.tts_audio_files
      assert is_integer(n1) and is_integer(n2)
    end
  end

  defp ready_request!(dir, filename) do
    feed = feed!()
    entry = entry!(feed)
    {:ok, request} = TTS.record_request(entry.id)

    request
    |> change(state: :ready, audio_path: filename)
    |> Repo.update!()

    File.write!(Path.join(dir, filename), "audio-bytes-" <> filename)

    %{request: Repo.get!(TTS.Request, request.id), entry: entry}
  end

  defp request_row!(entry_id, attrs) do
    {:ok, request} = TTS.record_request(entry_id)

    request
    |> change(attrs)
    |> Repo.update!()
  end

  defp backdate_request!(%TTS.Request{} = request, days_ago) do
    ts =
      DateTime.utc_now()
      |> DateTime.add(-days_ago * 86_400, :second)
      |> DateTime.truncate(:second)

    from(r in TTS.Request, where: r.id == ^request.id)
    |> Repo.update_all(set: [updated_at: ts])

    Repo.get!(TTS.Request, request.id)
  end

  defp backdate_file!(path, hours_ago: hours) do
    past = :calendar.datetime_to_gregorian_seconds(:calendar.universal_time()) - hours * 3_600

    File.touch!(path, :calendar.gregorian_seconds_to_datetime(past))
  end

  defp put_retention_config(overrides) do
    prev = Application.get_env(:earss, :retention, [])
    Application.put_env(:earss, :retention, Keyword.merge(prev, overrides))
  end

  # Application.get_env/3 only falls back to the default when the key is
  # *unset* — an explicit nil leaks into unrelated tests. Delete instead.
  defp restore_env(app, key, value) do
    if value == nil,
      do: Application.delete_env(app, key),
      else: Application.put_env(app, key, value)
  end
end
