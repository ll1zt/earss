defmodule Earss.Feeds.EntryTranslationTest do
  use Earss.DataCase

  alias Earss.Repo
  alias Earss.Feeds
  alias Earss.Feeds.{Entry, EntryTranslation}
  alias Earss.Reader.{AnchorUser, Subscription}

  defp unique_link do
    "https://example.com/feed_#{System.unique_integer([:positive])}.xml"
  end

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
      title: "Post #{n}",
      content: "<p>Hello</p>"
    }

    %Entry{}
    |> Entry.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  describe "feed translation fields" do
    test "default to disabled" do
      feed = insert_feed!()
      assert feed.translate_to == nil
      assert feed.translate_from == nil
      assert feed.translate_error_count == 0
    end

    test "create_feed accepts valid language tags" do
      feed = insert_feed!(%{translate_to: "zh", translate_from: "en"})
      assert feed.translate_to == "zh"
      assert feed.translate_from == "en"
    end

    test "rejects invalid language tags" do
      assert {:error, changeset} =
               Feeds.create_feed(%{link: unique_link(), translate_to: "english"})

      assert %{translate_to: _} = errors_on(changeset)
    end

    test "update_feed can enable and disable translation" do
      feed = insert_feed!()
      assert {:ok, feed} = Feeds.update_feed(feed, %{translate_to: "zh"})
      assert feed.translate_to == "zh"

      assert {:ok, feed} = Feeds.update_feed(feed, %{translate_to: nil})
      assert is_nil(feed.translate_to)
    end

    test "original_layout defaults and validates" do
      feed = insert_feed!(%{translate_to: "zh"})
      assert feed.original_layout == "off"

      assert {:ok, feed} = Feeds.update_feed(feed, %{original_layout: "interleaved"})
      assert feed.original_layout == "interleaved"

      assert {:error, changeset} = Feeds.update_feed(feed, %{original_layout: "bogus"})
      assert %{original_layout: _} = errors_on(changeset)
    end
  end

  describe "subscription translation fields" do
    test "default to follow-feed with inline original layout" do
      feed = insert_feed!()

      sub =
        %Subscription{}
        |> Subscription.changeset(%{user_id: AnchorUser.id(), feed_id: feed.id})
        |> Repo.insert!()

      assert sub.translate_to == nil
      assert sub.original_layout == "inline"
    end

    test "accepts a per-subscription override and layout" do
      feed = insert_feed!()

      sub =
        %Subscription{}
        |> Subscription.changeset(%{
          user_id: AnchorUser.id(),
          feed_id: feed.id,
          translate_to: "zh",
          original_layout: "off"
        })
        |> Repo.insert!()

      assert sub.translate_to == "zh"
      assert sub.original_layout == "off"
    end

    test "rejects an invalid language tag" do
      feed = insert_feed!()

      assert {:error, changeset} =
               %Subscription{}
               |> Subscription.changeset(%{
                 user_id: AnchorUser.id(),
                 feed_id: feed.id,
                 translate_to: "zzz!"
               })
               |> Repo.insert()

      assert %{translate_to: _} = errors_on(changeset)
    end
  end

  describe "entry_translations" do
    test "stores one translation per (entry, lang)" do
      feed = insert_feed!()
      entry = insert_entry!(feed)

      assert {:ok, translation} =
               %EntryTranslation{}
               |> EntryTranslation.changeset(%{
                 entry_id: entry.id,
                 lang: "zh",
                 title: "你好",
                 content: "<p>你好</p>",
                 original_hash: entry.content_hash,
                 model: "test-model",
                 translated_at: now()
               })
               |> Repo.insert()

      assert translation.lang == "zh"
      assert translation.title == "你好"
      assert translation.original_hash == entry.content_hash

      # same (entry, lang) rejected by unique index
      assert {:error, changeset} =
               %EntryTranslation{}
               |> EntryTranslation.changeset(%{
                 entry_id: entry.id,
                 lang: "zh",
                 translated_at: now()
               })
               |> Repo.insert()

      assert errors_on(changeset) != %{}

      # different lang allowed
      assert {:ok, _} =
               %EntryTranslation{}
               |> EntryTranslation.changeset(%{
                 entry_id: entry.id,
                 lang: "ja",
                 translated_at: now()
               })
               |> Repo.insert()
    end

    test "requires entry, lang and translated_at" do
      assert {:error, changeset} =
               %EntryTranslation{}
               |> EntryTranslation.changeset(%{})
               |> Repo.insert()

      assert %{entry_id: _, lang: _, translated_at: _} = errors_on(changeset)
    end

    test "rejects invalid lang" do
      feed = insert_feed!()
      entry = insert_entry!(feed)

      assert {:error, changeset} =
               %EntryTranslation{}
               |> EntryTranslation.changeset(%{
                 entry_id: entry.id,
                 lang: "中文",
                 translated_at: now()
               })
               |> Repo.insert()

      assert %{lang: _} = errors_on(changeset)
    end

    test "deleting an entry cascades its translations" do
      feed = insert_feed!()
      entry = insert_entry!(feed)

      %EntryTranslation{}
      |> EntryTranslation.changeset(%{entry_id: entry.id, lang: "zh", translated_at: now()})
      |> Repo.insert!()

      Repo.delete!(entry)
      assert Repo.aggregate(EntryTranslation, :count) == 0
    end
  end
end
