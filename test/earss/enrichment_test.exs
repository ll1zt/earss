defmodule Earss.EnrichmentTest do
  use Earss.DataCase

  import Ecto.Query, warn: false

  alias Earss.Repo
  alias Earss.Feeds
  alias Earss.Feeds.{Entry, EntryTranslation}
  alias Earss.Reader.{Subscription, User}
  alias Earss.Enrichment
  alias Earss.Test.FakeTranslator

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
      title: "Hello world",
      content: "<p>See <a href=\"https://x.com\">X</a> for details.</p>",
      content_hash: "hash-#{n}"
    }

    %Entry{}
    |> Entry.changeset(Map.merge(defaults, Map.new(attrs)))
    |> Repo.insert!()
  end

  defp insert_user! do
    %User{}
    |> User.changeset(%{
      username: "user_#{System.unique_integer([:positive])}",
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

  defp fetch_translation(entry, lang) do
    Repo.get_by(EntryTranslation, entry_id: entry.id, lang: lang)
  end

  defp insert_translation!(entry, lang, title, content) do
    %EntryTranslation{}
    |> EntryTranslation.changeset(%{
      entry_id: entry.id,
      lang: lang,
      title: title,
      content: content,
      original_hash: entry.content_hash,
      model: "test",
      translated_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert!()
  end

  describe "languages_for_feed/1" do
    test "collects feed config and per-subscription overrides" do
      feed = insert_feed!(%{translate_to: "zh"})
      user = insert_user!()
      subscribe!(user, feed, %{translate_to: "ja"})
      subscribe!(insert_user!(), feed, %{translate_to: "ja"})
      subscribe!(insert_user!(), feed)

      assert Enrichment.languages_for_feed(feed) == ["zh", "ja"]
    end

    test "returns empty when nothing is configured" do
      feed = insert_feed!()
      assert Enrichment.languages_for_feed(feed) == []
    end
  end

  describe "enrich_entry/3" do
    test "enriches into the feed language and stores HTML content verbatim" do
      feed = insert_feed!(%{translate_to: "zh"})
      entry = insert_entry!(feed)

      assert {:ok, 1} = Enrichment.enrich_entry(entry, feed, enricher: FakeTranslator)

      translation = fetch_translation(entry, "zh")
      assert translation.title == "[译]Hello world"
      assert translation.content =~ "[译]<p>See "
      assert translation.content =~ ~s(<a href="https://x.com">X</a>)
      assert translation.original_hash == entry.content_hash
      assert translation.model == "test_translator"
      # the registry key for block-structure lookups (interleaved layout)
      assert translation.enricher_id == "test_translator"
    end

    test "touches the entry so GReader clients refresh their cache" do
      feed = insert_feed!(%{translate_to: "zh"})
      entry = insert_entry!(feed)

      before = Repo.reload!(entry).updated_at
      # ensure we cross a second boundary (updated_at is second-precision)
      Process.sleep(1_100)

      assert {:ok, 1} = Enrichment.enrich_entry(entry, feed, enricher: FakeTranslator)

      after_touch = Repo.reload!(entry).updated_at
      assert DateTime.compare(after_touch, before) == :gt

      # idempotent re-run (nothing new stored) must NOT touch again
      assert {:ok, 0} = Enrichment.enrich_entry(entry, feed, enricher: FakeTranslator)
      assert Repo.reload!(entry).updated_at == after_touch
    end

    test "enriches into every language the feed needs" do
      feed = insert_feed!(%{translate_to: "zh"})
      user = insert_user!()
      subscribe!(user, feed, %{translate_to: "ja"})
      entry = insert_entry!(feed)

      assert {:ok, 2} = Enrichment.enrich_entry(entry, feed, enricher: FakeTranslator)
      assert fetch_translation(entry, "zh")
      assert fetch_translation(entry, "ja")
    end

    test "is idempotent for unchanged entries" do
      feed = insert_feed!(%{translate_to: "zh"})
      entry = insert_entry!(feed)

      assert {:ok, 1} = Enrichment.enrich_entry(entry, feed, enricher: FakeTranslator)
      assert {:ok, 0} = Enrichment.enrich_entry(entry, feed, enricher: FakeTranslator)
      assert Repo.aggregate(EntryTranslation, :count, filter: [entry_id: entry.id]) == 1
    end

    test "plugin skip? stores an original-text copy so the entry becomes visible" do
      feed = insert_feed!(%{translate_to: "zh"})
      entry = insert_entry!(feed, title: "SKIPME title")

      Process.put(:fake_skip, true)
      on_exit(fn -> Process.delete(:fake_skip) end)

      assert {:ok, 1} = Enrichment.enrich_entry(entry, feed, enricher: FakeTranslator)

      translation = fetch_translation(entry, "zh")
      assert translation.title == "SKIPME title"
      assert translation.content == entry.content
    end

    test "provider errors bump the error count and never write" do
      feed = insert_feed!(%{translate_to: "zh"})
      entry = insert_entry!(feed)

      Process.put(:fake_behavior, :error)
      on_exit(fn -> Process.delete(:fake_behavior) end)

      assert {:ok, 0} = Enrichment.enrich_entry(entry, feed, enricher: FakeTranslator)
      assert fetch_translation(entry, "zh") == nil
      assert Repo.reload!(feed).translate_error_count == 1
    end

    test "ref mismatch (plugin drops entries) rejects the whole batch" do
      feed = insert_feed!(%{translate_to: "zh"})
      entry = insert_entry!(feed)

      Process.put(:fake_behavior, :skip_all)
      on_exit(fn -> Process.delete(:fake_behavior) end)

      assert {:ok, 0} = Enrichment.enrich_entry(entry, feed, enricher: FakeTranslator)
      assert fetch_translation(entry, "zh") == nil
      assert Repo.reload!(feed).translate_error_count == 1
    end
  end

  describe "enrich_new_entries/3" do
    test "caps the number of entries at the budget" do
      feed = insert_feed!(%{translate_to: "zh"})
      entries = Enum.map(1..5, fn _ -> insert_entry!(feed) end)

      assert {:ok, 2} =
               Enrichment.enrich_new_entries(feed, entries,
                 enricher: FakeTranslator,
                 budget: %{max_entries: 2, max_chars: 100_000}
               )

      translated = Enum.count(entries, fn e -> fetch_translation(e, "zh") != nil end)
      assert translated == 2
    end
  end

  describe "enricher/0" do
    test "picks the first registered enricher sorted by id" do
      # "aaa_" sorts before any other fake id other test files may register
      id = "aaa_enricher_#{System.unique_integer([:positive])}"
      assert :ok == Earss.Enrichment.Registry.register(%{id: id, module: FakeTranslator})
      on_exit(fn -> Earss.Enrichment.Registry.unregister(id) end)

      assert Enrichment.enricher() == FakeTranslator
    end
  end

  describe "stats/1" do
    test "reports total, need (not stock), pending, per-language counts and errors" do
      feed = insert_feed!(%{translate_to: "zh"})
      e1 = insert_entry!(feed)
      e2 = insert_entry!(feed)
      e3 = insert_entry!(feed)

      insert_translation!(e1, "zh", "译一", "<p>一</p>")
      insert_translation!(e2, "zh", "译二", "<p>二</p>")

      s = Enrichment.stats(feed)
      assert s.total == 3
      assert s.need == 2
      assert s.pending == 0
      assert s.languages == %{"zh" => 2}
      assert s.errors == 0

      _ = e3
    end

    test "pending entries count toward need but not total translated" do
      feed = insert_feed!(%{translate_to: "zh"})
      e1 = insert_entry!(feed)
      e2 = insert_entry!(feed)
      _e3 = insert_entry!(feed)

      insert_translation!(e1, "zh", "译一", "<p>一</p>")
      :ok = Enrichment.mark_pending(feed, [e2])

      s = Enrichment.stats(feed)
      # e3 is stock (never marked pending): not part of need
      assert s.total == 3
      assert s.need == 2
      assert s.pending == 1
      assert s.languages == %{"zh" => 1}
    end
  end

  describe "pending model" do
    test "mark_pending flags new entries of translated feeds only" do
      feed = insert_feed!(%{translate_to: "zh"})
      e1 = insert_entry!(feed)
      feed2 = insert_feed!()
      e2 = insert_entry!(feed2)

      assert :ok = Enrichment.mark_pending(feed, [e1])
      assert :ok = Enrichment.mark_pending(feed2, [e2])

      assert Repo.get!(Entry, e1.id).translation_pending_at != nil
      assert Repo.get!(Entry, e2.id).translation_pending_at == nil
    end

    test "mark_pending does not re-flag entries with fresh translations" do
      feed = insert_feed!(%{translate_to: "zh"})
      entry = insert_entry!(feed)
      insert_translation!(entry, "zh", "译题", "<p>译正文</p>")

      assert :ok = Enrichment.mark_pending(feed, [entry])
      assert Repo.get!(Entry, entry.id).translation_pending_at == nil
    end

    test "mark_pending never resets retry count or pause marker" do
      feed = insert_feed!(%{translate_to: "zh"})
      entry = insert_entry!(feed)

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      from(e in Entry, where: e.id == ^entry.id)
      |> Repo.update_all(set: [translation_retry_count: 5, translation_paused_at: now])

      assert :ok = Enrichment.mark_pending(feed, [entry])

      stored = Repo.get!(Entry, entry.id)
      assert stored.translation_retry_count == 5
      assert stored.translation_paused_at == now
    end

    test "mark_pending with a changed entry re-flags it for re-translation" do
      feed = insert_feed!(%{translate_to: "zh"})
      entry = insert_entry!(feed)
      insert_translation!(entry, "zh", "译题", "<p>译正文</p>")

      # the entry is re-fetched with new content → new content_hash
      {:ok, updated} =
        Feeds.upsert_entry(feed, %{
          link: entry.link,
          guid: entry.guid,
          title: entry.title,
          content: "<p>changed body</p>"
        })

      assert updated.content_hash != entry.content_hash
      assert :ok = Enrichment.mark_pending(feed, [updated])
      assert Repo.get!(Entry, updated.id).translation_pending_at != nil
    end

    test "enrich_entry clears pending when all languages are ready" do
      feed = insert_feed!(%{translate_to: "zh"})
      entry = insert_entry!(feed)
      :ok = Enrichment.mark_pending(feed, [entry])

      assert {:ok, 1} = Enrichment.enrich_entry(entry, feed, enricher: FakeTranslator)
      assert Repo.get!(Entry, entry.id).translation_pending_at == nil
    end

    test "failed enrichment keeps the entry pending for retry" do
      feed = insert_feed!(%{translate_to: "zh"})
      entry = insert_entry!(feed)
      :ok = Enrichment.mark_pending(feed, [entry])

      Process.put(:fake_behavior, :error)
      on_exit(fn -> Process.delete(:fake_behavior) end)

      assert {:ok, 0} = Enrichment.enrich_entry(entry, feed, enricher: FakeTranslator)
      assert Repo.get!(Entry, entry.id).translation_pending_at != nil
      assert Repo.reload!(feed).translate_error_count == 1
    end

    test "process_pending retries pending entries and clears ready ones" do
      feed = insert_feed!(%{translate_to: "zh"})
      pending = insert_entry!(feed)
      :ok = Enrichment.mark_pending(feed, [pending])

      assert Enrichment.process_pending(100, enricher: FakeTranslator) >= 1
      assert Repo.get!(Entry, pending.id).translation_pending_at == nil
      assert fetch_translation(pending, "zh") != nil
    end

    test "process_pending clears orphaned flags when translation is disabled" do
      feed = insert_feed!(%{translate_to: "zh"})
      entry = insert_entry!(feed)
      :ok = Enrichment.mark_pending(feed, [entry])
      {:ok, _feed} = Feeds.update_feed(feed, %{translate_to: nil})

      assert Enrichment.process_pending(100, enricher: FakeTranslator) == 0
      assert Repo.get!(Entry, entry.id).translation_pending_at == nil
    end

    test "process_pending clears PAUSED orphans when no target remains" do
      feed = insert_feed!(%{translate_to: "zh"})
      entry = insert_entry!(feed)
      :ok = Enrichment.mark_pending(feed, [entry])

      # drive the entry into the paused state (5 failed attempts)
      Process.put(:fake_behavior, :error)
      on_exit(fn -> Process.delete(:fake_behavior) end)
      Enum.each(1..5, fn _ -> Enrichment.process_pending(100, enricher: FakeTranslator) end)

      entry = Repo.get!(Entry, entry.id)
      assert entry.translation_pending_at != nil
      assert entry.translation_paused_at != nil

      # the last translation target disappears → paused entries must not
      # stay hidden forever
      {:ok, _feed} = Feeds.update_feed(feed, %{translate_to: nil})
      assert Enrichment.process_pending(100, enricher: FakeTranslator) == 0

      entry = Repo.get!(Entry, entry.id)
      assert entry.translation_pending_at == nil
      assert entry.translation_paused_at == nil
    end

    test "process_pending clears pending entries when no enricher is registered" do
      feed = insert_feed!(%{translate_to: "zh"})
      entry = insert_entry!(feed)
      :ok = Enrichment.mark_pending(feed, [entry])

      # Simulate a removed plugin: empty the registry (the dev earss.env
      # registers the real openai translator at app boot, which would
      # otherwise be picked and would make a real provider call).
      registered = Earss.Enrichment.Registry.list_enrichers()

      Enum.each(registered, fn %{id: id} -> Earss.Enrichment.Registry.unregister(id) end)

      on_exit(fn ->
        Enum.each(registered, fn %{id: id, module: mod, version: version} ->
          Earss.Enrichment.Registry.register(%{id: id, module: mod, version: version})
        end)
      end)

      assert Enrichment.process_pending(100) == 0
      assert Repo.get!(Entry, entry.id).translation_pending_at == nil
    end

    test "process_pending pauses after max retries (hidden, waiting for admin)" do
      feed = insert_feed!(%{translate_to: "zh"})
      entry = insert_entry!(feed)
      :ok = Enrichment.mark_pending(feed, [entry])

      Process.put(:fake_behavior, :error)
      on_exit(fn -> Process.delete(:fake_behavior) end)

      # each process_pending run is one failed attempt; max_pending_retries (5)
      # attempts later the entry is paused — still pending (hidden), NOT
      # published, and skipped by further retries
      Enum.each(1..4, fn _ ->
        assert Enrichment.process_pending(100, enricher: FakeTranslator) == 0
      end)

      assert Repo.get!(Entry, entry.id).translation_pending_at != nil
      assert Repo.get!(Entry, entry.id).translation_paused_at == nil

      assert Enrichment.process_pending(100, enricher: FakeTranslator) == 0
      entry = Repo.get!(Entry, entry.id)
      assert entry.translation_pending_at != nil
      assert entry.translation_paused_at != nil

      # paused entries are not retried anymore
      assert Enrichment.process_pending(100, enricher: FakeTranslator) == 0
      assert Repo.get!(Entry, entry.id).translation_paused_at != nil
    end

    test "retry_paused clears the pause so the pending worker resumes" do
      feed = insert_feed!(%{translate_to: "zh"})
      entry = insert_entry!(feed)
      :ok = Enrichment.mark_pending(feed, [entry])

      Process.put(:fake_behavior, :error)
      on_exit(fn -> Process.delete(:fake_behavior) end)

      Enum.each(1..5, fn _ -> Enrichment.process_pending(100, enricher: FakeTranslator) end)
      assert Repo.get!(Entry, entry.id).translation_paused_at != nil

      assert :ok = Enrichment.retry_paused(feed)
      entry = Repo.get!(Entry, entry.id)
      assert entry.translation_paused_at == nil
      assert entry.translation_retry_count == 0
      assert entry.translation_pending_at != nil

      # resumes translating; with the fake healthy again it completes
      Process.delete(:fake_behavior)
      assert Enrichment.process_pending(100, enricher: FakeTranslator) >= 1
      assert Repo.get!(Entry, entry.id).translation_pending_at == nil
    end

    test "publish_pending publishes the original without translating" do
      feed = insert_feed!(%{translate_to: "zh"})
      entry = insert_entry!(feed)
      :ok = Enrichment.mark_pending(feed, [entry])

      assert :ok = Enrichment.publish_pending(feed)
      entry = Repo.get!(Entry, entry.id)
      assert entry.translation_pending_at == nil
      assert entry.translation_paused_at == nil
      assert Repo.get_by(EntryTranslation, entry_id: entry.id) == nil
    end

    test "process_pending retries while under the retry limit" do
      feed = insert_feed!(%{translate_to: "zh"})
      entry = insert_entry!(feed)
      :ok = Enrichment.mark_pending(feed, [entry])

      Process.put(:fake_behavior, :error)
      on_exit(fn -> Process.delete(:fake_behavior) end)

      # fresh pending flag → retried, still pending after a couple of failures
      assert Enrichment.process_pending(100, enricher: FakeTranslator) == 0
      assert Enrichment.process_pending(100, enricher: FakeTranslator) == 0
      assert Repo.get!(Entry, entry.id).translation_pending_at != nil
      assert Repo.get!(Entry, entry.id).translation_retry_count == 2
    end

    test "clear_pending makes originals visible again" do
      feed = insert_feed!(%{translate_to: "zh"})
      entry = insert_entry!(feed)
      :ok = Enrichment.mark_pending(feed, [entry])

      assert :ok = Enrichment.clear_pending(feed)
      assert Repo.get!(Entry, entry.id).translation_pending_at == nil
    end
  end
end
