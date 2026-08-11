defmodule Earss.API.TranslationTest do
  use Earss.DataCase

  alias Earss.API.Translation
  alias Earss.Repo
  alias Earss.Feeds
  alias Earss.Feeds.{Entry, EntryTranslation}
  alias Earss.Reader.User

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
      model: "test",
      translated_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert!()
  end

  defp row(entry, feed, opts \\ []) do
    %{
      entry: entry,
      feed: feed,
      sub_translate_to: Keyword.get(opts, :sub_translate_to),
      return_original: Keyword.get(opts, :return_original, true)
    }
  end

  test "no configuration → original content, zero change" do
    feed = insert_feed!()
    entry = insert_entry!(feed)
    [decorated] = Translation.attach(nil, [row(entry, feed)])

    assert Translation.title(decorated) == "Original title"
    assert Translation.content(decorated) == "<p>Original body</p>"
    assert decorated.translation == nil
  end

  test "feed-level translation substitutes title/content without concatenation" do
    feed = insert_feed!(%{translate_to: "zh"})
    entry = insert_entry!(feed)
    insert_translation!(entry, "zh", "译题", "<p>译正文</p>")

    [decorated] = Translation.attach(nil, [row(entry, feed)])
    assert Translation.title(decorated) == "译题"
    assert Translation.content(decorated) == "<p>译正文</p>"
    refute decorated.append_original
  end

  test "subscription override appends original by default" do
    feed = insert_feed!(%{translate_to: "zh"})
    entry = insert_entry!(feed)
    insert_translation!(entry, "zh", "译题", "<p>译正文</p>")

    [decorated] =
      Translation.attach(nil, [row(entry, feed, sub_translate_to: "zh", return_original: true)])

    assert Translation.content(decorated) ==
             "<p>译正文</p><hr class=\"earss-original\"><p>Original body</p>"

    assert decorated.append_original
  end

  test "return_original false → translated content only" do
    feed = insert_feed!(%{translate_to: "zh"})
    entry = insert_entry!(feed)
    insert_translation!(entry, "zh", "译题", "<p>译正文</p>")

    [decorated] =
      Translation.attach(nil, [row(entry, feed, sub_translate_to: "zh", return_original: false)])

    assert Translation.content(decorated) == "<p>译正文</p>"
  end

  test "original: true opt bypasses the view entirely" do
    feed = insert_feed!(%{translate_to: "zh"})
    entry = insert_entry!(feed)
    insert_translation!(entry, "zh", "译题", "<p>译正文</p>")

    [decorated] = Translation.attach(nil, [row(entry, feed)], original: true)
    assert Translation.title(decorated) == "Original title"
    assert Translation.content(decorated) == "<p>Original body</p>"
  end

  test "configured but no stored translation → original" do
    feed = insert_feed!(%{translate_to: "zh"})
    entry = insert_entry!(feed)

    [decorated] = Translation.attach(nil, [row(entry, feed)])
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

    assert [r1, r2] = Translation.attach(nil, rows)
    assert Translation.title(r1) == "译一"
    assert Translation.title(r2) == "译二"
  end

  test "subscription override takes precedence over feed language" do
    feed = insert_feed!(%{translate_to: "zh"})
    entry = insert_entry!(feed)
    insert_translation!(entry, "ja", "和題", "<p>和文</p>")

    [decorated] = Translation.attach(nil, [row(entry, feed, sub_translate_to: "ja")])
    assert Translation.title(decorated) == "和題"
  end

  test "feed-level return_original appends the original" do
    feed = insert_feed!(%{translate_to: "zh", return_original: true})
    entry = insert_entry!(feed)
    insert_translation!(entry, "zh", "译题", "<p>译正文</p>")

    [decorated] = Translation.attach(nil, [row(entry, feed)])
    assert decorated.append_original

    assert Translation.content(decorated) ==
             "<p>译正文</p><hr class=\"earss-original\"><p>Original body</p>"
  end

  test "feed-level translation without return_original is translated only" do
    feed = insert_feed!(%{translate_to: "zh"})
    entry = insert_entry!(feed)
    insert_translation!(entry, "zh", "译题", "<p>译正文</p>")

    [decorated] = Translation.attach(nil, [row(entry, feed)])
    refute decorated.append_original
    assert Translation.content(decorated) == "<p>译正文</p>"
  end
end
