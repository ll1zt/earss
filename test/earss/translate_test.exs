defmodule Earss.TranslateTest do
  use Earss.DataCase

  alias Earss.Repo
  alias Earss.Feeds
  alias Earss.Feeds.{Entry, EntryTranslation}
  alias Earss.Reader.{Subscription, User}
  alias Earss.Translate
  alias Earss.Translate.Lang
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

  describe "languages_for_feed/1" do
    test "collects feed config and per-subscription overrides" do
      feed = insert_feed!(%{translate_to: "zh"})
      user = insert_user!()
      subscribe!(user, feed, %{translate_to: "ja"})
      subscribe!(insert_user!(), feed, %{translate_to: "ja"})
      subscribe!(insert_user!(), feed)

      assert Translate.languages_for_feed(feed) == ["zh", "ja"]
    end

    test "returns empty when nothing is configured" do
      feed = insert_feed!()
      assert Translate.languages_for_feed(feed) == []
    end
  end

  describe "translate_entry/3" do
    test "translates into the feed language and stores HTML content" do
      feed = insert_feed!(%{translate_to: "zh"})
      entry = insert_entry!(feed)

      assert {:ok, 1} = Translate.translate_entry(entry, feed, translator: FakeTranslator)

      translation = fetch_translation(entry, "zh")
      assert translation.title == "[译]Hello world"
      assert translation.content =~ "[译]See "
      assert translation.content =~ ~s(<a href="https://x.com">X</a>)
      assert translation.original_hash == entry.content_hash
      assert translation.model == "test_translator"
    end

    test "touches the entry so GReader clients refresh their cache" do
      feed = insert_feed!(%{translate_to: "zh"})
      entry = insert_entry!(feed)

      before = Repo.reload!(entry).updated_at
      # ensure we cross a second boundary (updated_at is second-precision)
      Process.sleep(1_100)

      assert {:ok, 1} = Translate.translate_entry(entry, feed, translator: FakeTranslator)

      after_touch = Repo.reload!(entry).updated_at
      assert DateTime.compare(after_touch, before) == :gt

      # idempotent re-run (nothing new stored) must NOT touch again
      assert {:ok, 0} = Translate.translate_entry(entry, feed, translator: FakeTranslator)
      assert Repo.reload!(entry).updated_at == after_touch
    end

    test "translates into every language the feed needs" do
      feed = insert_feed!(%{translate_to: "zh"})
      user = insert_user!()
      subscribe!(user, feed, %{translate_to: "ja"})
      entry = insert_entry!(feed)

      assert {:ok, 2} = Translate.translate_entry(entry, feed, translator: FakeTranslator)
      assert fetch_translation(entry, "zh")
      assert fetch_translation(entry, "ja")
    end

    test "is idempotent for unchanged entries" do
      feed = insert_feed!(%{translate_to: "zh"})
      entry = insert_entry!(feed)

      assert {:ok, 1} = Translate.translate_entry(entry, feed, translator: FakeTranslator)
      assert {:ok, 0} = Translate.translate_entry(entry, feed, translator: FakeTranslator)
      assert Repo.aggregate(EntryTranslation, :count, filter: [entry_id: entry.id]) == 1
    end

    test "skips entries the local heuristic considers already in the target lang" do
      feed = insert_feed!(%{translate_to: "zh"})
      entry = insert_entry!(feed, title: "中文标题", content: "<p>这是一段中文内容，不需要翻译。</p>")

      assert {:ok, 0} = Translate.translate_entry(entry, feed, translator: FakeTranslator)
      assert fetch_translation(entry, "zh") == nil
    end

    test "honours the plugin skip?/2 pre-filter" do
      feed = insert_feed!(%{translate_to: "zh"})
      entry = insert_entry!(feed, title: "SKIPME title")

      Process.put(:fake_skip, true)
      on_exit(fn -> Process.delete(:fake_skip) end)

      assert {:ok, 0} = Translate.translate_entry(entry, feed, translator: FakeTranslator)
      assert fetch_translation(entry, "zh") == nil
    end

    test "provider errors bump the error count and never write" do
      feed = insert_feed!(%{translate_to: "zh"})
      entry = insert_entry!(feed)

      Process.put(:fake_behavior, :error)
      on_exit(fn -> Process.delete(:fake_behavior) end)

      assert {:ok, 0} = Translate.translate_entry(entry, feed, translator: FakeTranslator)
      assert fetch_translation(entry, "zh") == nil
      assert Repo.reload!(feed).translate_error_count == 1
    end

    test "placeholder corruption falls back to the original block" do
      feed = insert_feed!(%{translate_to: "zh"})
      entry = insert_entry!(feed)

      Process.put(:fake_behavior, :drop_placeholder)
      on_exit(fn -> Process.delete(:fake_behavior) end)

      assert {:ok, 1} = Translate.translate_entry(entry, feed, translator: FakeTranslator)

      translation = fetch_translation(entry, "zh")
      # drop_placeholder branch prefixes nothing; title has no tokens → unchanged.
      # Corrupted content block (tokens replaced) → falls back to the original block.
      assert translation.title == "Hello world"
      assert translation.content =~ ~s(<a href="https://x.com">X</a>)
    end
  end

  describe "translate_new_entries/3" do
    test "caps the number of entries at the budget" do
      feed = insert_feed!(%{translate_to: "zh"})
      entries = Enum.map(1..5, fn _ -> insert_entry!(feed) end)

      assert {:ok, 2} =
               Translate.translate_new_entries(feed, entries,
                 translator: FakeTranslator,
                 budget: %{max_entries: 2, max_chars: 100_000}
               )

      translated = Enum.count(entries, fn e -> fetch_translation(e, "zh") != nil end)
      assert translated == 2
    end
  end

  describe "translator/0" do
    test "picks the first registered translator sorted by id" do
      # "aaa_" sorts before any other fake id other test files may register
      id = "aaa_translator_#{System.unique_integer([:positive])}"
      assert :ok == Earss.Translate.Registry.register(%{id: id, module: FakeTranslator})
      on_exit(fn -> Earss.Translate.Registry.unregister(id) end)

      assert Translate.translator() == FakeTranslator
    end
  end

  describe "backfill_feed/2" do
    test "translates all existing entries of a feed" do
      feed = insert_feed!(%{translate_to: "zh"})
      Enum.each(1..3, fn _ -> insert_entry!(feed) end)

      assert {:ok, 3} = Translate.backfill_feed(feed, translator: FakeTranslator)
      assert Repo.aggregate(EntryTranslation, :count) == 3
    end

    test "is idempotent across runs" do
      feed = insert_feed!(%{translate_to: "zh"})
      Enum.each(1..2, fn _ -> insert_entry!(feed) end)

      assert {:ok, 2} = Translate.backfill_feed(feed, translator: FakeTranslator)
      assert {:ok, 0} = Translate.backfill_feed(feed, translator: FakeTranslator)
      assert Repo.aggregate(EntryTranslation, :count) == 2
    end

    test "errors when no language is configured" do
      feed = insert_feed!()
      insert_entry!(feed)

      assert {:error, :no_language_configured} =
               Translate.backfill_feed(feed, translator: FakeTranslator)
    end

    test "a failing entry does not roll back already-stored translations" do
      feed = insert_feed!(%{translate_to: "zh"})
      ok_entry = insert_entry!(feed, title: "Good entry")
      bad_entry = insert_entry!(feed, title: "BAD entry")

      Process.put(:fake_behavior, :error_on_bad)
      on_exit(fn -> Process.delete(:fake_behavior) end)

      # ok_entry is persisted in its own short transaction; bad_entry fails
      # without aborting the run or undoing the success.
      assert {:ok, 1} = Translate.backfill_feed(feed, translator: FakeTranslator)
      assert fetch_translation(ok_entry, "zh") != nil
      assert fetch_translation(bad_entry, "zh") == nil
      assert Repo.reload!(feed).translate_error_count == 1
    end
  end

  describe "Lang.skip?/2 heuristics" do
    test "skips Chinese text for zh targets" do
      assert Lang.skip?("这是一段中文内容。", "zh")
      refute Lang.skip?("This is English content.", "zh")
      assert Lang.skip?("", "zh") == false
    end

    test "never skips Japanese for zh targets even with dense kanji" do
      # kanji-dense headline with katakana — clearly Japanese, must translate
      ja_headline =
        "合格発表 先端科学技術研究科 博士前期課程【情報科学区分、バイオサイエンス区分、物質創成科学区分】"

      ja_article = "生駒市との第2期包括連携協定締結及び連携協議会を開催しました。本学と生駒市は、"
      refute Lang.skip?(ja_headline, "zh")
      refute Lang.skip?(ja_article, "zh")
    end

    test "Chinese text with a Japanese kanji (not kana) still skips for zh" do
      # kanji overlaps with CJK; only kana marks a text as Japanese
      assert Lang.skip?("这是一段中文内容，包含'発表'这样的日文汉字。", "zh")
    end

    test "skips Japanese kana for ja targets" do
      assert Lang.skip?("これは日本語の内容です。", "ja")
      refute Lang.skip?("This is English.", "ja")
    end

    test "never skips for unknown targets" do
      refute Lang.skip?("こんにちは", "fr")
      refute Lang.skip?("你好", "fr")
    end
  end
end
