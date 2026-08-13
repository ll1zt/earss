defmodule Earss.API.TranslationTest do
  use Earss.DataCase

  alias Earss.API.Translation
  alias Earss.Repo
  alias Earss.Feeds
  alias Earss.Feeds.{Entry, EntryTranslation}
  alias Earss.Test.FakeTranslator

  setup do
    # The interleaved layout asks the plugin that produced the translation
    # (via its stored `model` id) for block structure.
    assert :ok ==
             Earss.Enrichment.Registry.register(%{
               id: "test_translator",
               module: FakeTranslator
             })

    on_exit(fn -> Earss.Enrichment.Registry.unregister("test_translator") end)
    :ok
  end

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

  defp insert_translation!(entry, lang, title, content) do
    %EntryTranslation{}
    |> EntryTranslation.changeset(%{
      entry_id: entry.id,
      lang: lang,
      title: title,
      content: content,
      original_hash: entry.content_hash,
      model: "gpt-4o-mini",
      enricher_id: "test_translator",
      translated_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert!()
  end

  defp row(entry, feed, opts \\ []) do
    %{
      entry: entry,
      feed: feed,
      sub_translate_to: Keyword.get(opts, :sub_translate_to),
      original_layout: Keyword.get(opts, :original_layout, "inline")
    }
  end

  test "no configuration → original content, zero change" do
    feed = insert_feed!()
    entry = insert_entry!(feed)
    [decorated] = Translation.attach([row(entry, feed)])

    assert Translation.title(decorated) == "Original title"
    assert Translation.content(decorated) == "<p>Original body</p>"
    assert decorated.translation == nil
  end

  test "feed-level translation substitutes title/content without concatenation" do
    feed = insert_feed!(%{translate_to: "zh"})
    entry = insert_entry!(feed)
    insert_translation!(entry, "zh", "译题", "<p>译正文</p>")

    [decorated] = Translation.attach([row(entry, feed)])
    assert Translation.title(decorated) == "译题"
    assert Translation.content(decorated) == "<p>译正文</p>"
    assert decorated.original_layout == "off"
  end

  test "subscription override appends original inline by default" do
    feed = insert_feed!(%{translate_to: "zh"})
    entry = insert_entry!(feed)
    insert_translation!(entry, "zh", "译题", "<p>译正文</p>")

    [decorated] = Translation.attach([row(entry, feed, sub_translate_to: "zh")])

    assert Translation.content(decorated) ==
             "<p>译正文</p><hr class=\"earss-original\"><p>Original body</p>"

    assert decorated.original_layout == "inline"
  end

  test "off layout → translated content only" do
    feed = insert_feed!(%{translate_to: "zh"})
    entry = insert_entry!(feed)
    insert_translation!(entry, "zh", "译题", "<p>译正文</p>")

    [decorated] =
      Translation.attach([row(entry, feed, sub_translate_to: "zh", original_layout: "off")])

    assert Translation.content(decorated) == "<p>译正文</p>"
  end

  test "section layout wraps the original in a styled section" do
    feed = insert_feed!(%{translate_to: "zh"})
    entry = insert_entry!(feed)
    insert_translation!(entry, "zh", "译题", "<p>译正文</p>")

    [decorated] =
      Translation.attach([
        row(entry, feed, sub_translate_to: "zh", original_layout: "section")
      ])

    assert Translation.content(decorated) ==
             "<p>译正文</p><hr class=\"earss-original\">" <>
               ~s(<div class="earss-original-section"><p>Original body</p></div>)
  end

  test "interleaved layout alternates translated and original blocks" do
    feed = insert_feed!(%{translate_to: "zh"})

    entry =
      insert_entry!(feed,
        content: "<p>First original paragraph.</p><p>Second original paragraph.</p>"
      )

    insert_translation!(entry, "zh", "译题", "<p>第一段译文。</p><p>第二段译文。</p>")

    [decorated] =
      Translation.attach([
        row(entry, feed, sub_translate_to: "zh", original_layout: "interleaved")
      ])

    assert Translation.content(decorated) ==
             "<p>第一段译文。</p>" <>
               ~s(<div class="earss-original-block"><p>First original paragraph.</p></div>) <>
               "<p>第二段译文。</p>" <>
               ~s(<div class="earss-original-block"><p>Second original paragraph.</p></div>)
  end

  test "interleaved resolves the splitter by enricher_id, not model string" do
    feed = insert_feed!(%{translate_to: "zh"})

    entry =
      insert_entry!(feed,
        content: "<p>First original paragraph.</p><p>Second original paragraph.</p>"
      )

    # the real plugin stores the LLM model name in `model` (e.g. gpt-4o-mini)
    # and its plugin id in `enricher_id`; the registry is keyed by plugin id
    insert_translation!(entry, "zh", "译题", "<p>第一段译文。</p><p>第二段译文。</p>")

    stored = Repo.get_by!(EntryTranslation, entry_id: entry.id, lang: "zh")
    assert stored.model == "gpt-4o-mini"
    assert stored.enricher_id == "test_translator"

    [decorated] =
      Translation.attach([
        row(entry, feed, sub_translate_to: "zh", original_layout: "interleaved")
      ])

    assert Translation.content(decorated) =~ "earss-original-block"
  end

  test "interleaved without a known enricher_id degrades to section layout" do
    feed = insert_feed!(%{translate_to: "zh"})
    entry = insert_entry!(feed, content: "<p>Original.</p>")

    %EntryTranslation{}
    |> EntryTranslation.changeset(%{
      entry_id: entry.id,
      lang: "zh",
      title: "译题",
      content: "<p>译文。</p>",
      original_hash: entry.content_hash,
      model: "unknown-plugin",
      translated_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert!()

    [decorated] =
      Translation.attach([
        row(entry, feed, sub_translate_to: "zh", original_layout: "interleaved")
      ])

    assert Translation.content(decorated) =~ "earss-original-section"
    refute Translation.content(decorated) =~ "earss-original-block"
  end

  test "inline layout with content already in target lang renders once (no dup)" do
    feed = insert_feed!(%{translate_to: "zh"})
    entry = insert_entry!(feed, content: "<p>中文内容，无需翻译。</p>")
    # plugin stores an original-text copy (already in target language)
    insert_translation!(entry, "zh", "中文标题", "<p>中文内容，无需翻译。</p>")

    [decorated] =
      Translation.attach([
        row(entry, feed, sub_translate_to: "zh", original_layout: "inline")
      ])

    assert Translation.content(decorated) == "<p>中文内容，无需翻译。</p>"
    refute Translation.content(decorated) =~ "earss-original"
  end

  test "original: true opt bypasses the view entirely" do
    feed = insert_feed!(%{translate_to: "zh"})
    entry = insert_entry!(feed)
    insert_translation!(entry, "zh", "译题", "<p>译正文</p>")

    [decorated] = Translation.attach([row(entry, feed)], original: true)
    assert Translation.title(decorated) == "Original title"
    assert Translation.content(decorated) == "<p>Original body</p>"
  end

  test "configured but no stored translation → original" do
    feed = insert_feed!(%{translate_to: "zh"})
    entry = insert_entry!(feed)

    [decorated] = Translation.attach([row(entry, feed)])
    assert decorated.translation == nil
    assert Translation.content(decorated) == "<p>Original body</p>"
  end

  test "handles many rows in one batch (per-language IN query)" do
    feed = insert_feed!(%{translate_to: "zh"})
    e1 = insert_entry!(feed)
    e2 = insert_entry!(feed)
    insert_translation!(e1, "zh", "译一", "<p>一</p>")
    insert_translation!(e2, "zh", "译二", "<p>二</p>")

    rows = [row(e1, feed), row(e2, feed)]

    assert [r1, r2] = Translation.attach(rows)
    assert Translation.title(r1) == "译一"
    assert Translation.title(r2) == "译二"
  end

  test "subscription override takes precedence over feed language" do
    feed = insert_feed!(%{translate_to: "zh"})
    entry = insert_entry!(feed)
    insert_translation!(entry, "ja", "和題", "<p>和文</p>")

    [decorated] = Translation.attach([row(entry, feed, sub_translate_to: "ja")])
    assert Translation.title(decorated) == "和題"
  end

  test "feed-level section layout appends a wrapped original" do
    feed = insert_feed!(%{translate_to: "zh", original_layout: "section"})
    entry = insert_entry!(feed)
    insert_translation!(entry, "zh", "译题", "<p>译正文</p>")

    [decorated] = Translation.attach([row(entry, feed)])
    assert decorated.original_layout == "section"

    assert Translation.content(decorated) ==
             "<p>译正文</p><hr class=\"earss-original\">" <>
               ~s(<div class="earss-original-section"><p>Original body</p></div>)
  end

  test "feed-level default (off) is translated only" do
    feed = insert_feed!(%{translate_to: "zh"})
    entry = insert_entry!(feed)
    insert_translation!(entry, "zh", "译题", "<p>译正文</p>")

    [decorated] = Translation.attach([row(entry, feed)])
    assert decorated.original_layout == "off"
    assert Translation.content(decorated) == "<p>译正文</p>"
  end
end
