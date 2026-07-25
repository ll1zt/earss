defmodule Earss.GReader.Format do
  @moduledoc false

  alias Earss.Feeds
  alias Earss.GReader.Ids

  def entry_item(%{
         entry: e,
         is_read: is_read,
         is_star: is_star,
         custom_title: custom_title
       } = row) do
    feed = Map.get(row, :feed) || Feeds.get_feed(e.feed_id)
    category_name = Map.get(row, :category_name)
    feed_title = custom_title || (feed && feed.title) || (feed && feed.link) || ""
    categories = build_item_categories(is_read, is_star, feed, category_name)

    # Crawl time as a floor so clients with "ignore old articles" still see
    # newly ingested posts whose feed published_at is ancient.
    published_unix = unix(e.published_at) || 0
    ingested_unix = unix(e.inserted_at) || 0
    sort_unix = max(published_unix, ingested_unix)
    crawl_msec = max(ingested_unix, published_unix) * 1000

    %{
      "id" => Ids.item_atom_id(e.id),
      "categories" => categories,
      "title" => e.title || "",
      "published" => sort_unix,
      "updated" => unix(e.updated_at) || sort_unix,
      "crawlTimeMsec" => Integer.to_string(crawl_msec),
      "canonical" => [%{"href" => e.link || ""}],
      "alternate" => [%{"href" => e.link || "", "type" => "text/html"}],
      "summary" => %{"content" => e.content || e.summary || "", "direction" => "ltr"},
      "author" => e.author || "",
      "origin" => %{
        "streamId" => if(feed, do: Ids.feed_stream_id(feed), else: ""),
        "title" => feed_title,
        "htmlUrl" => (feed && (feed.site_url || feed.link)) || ""
      },
      "timestampUsec" => "#{sort_unix}000000"
    }
  end

  defp build_item_categories(is_read, is_star, feed, category_name) do
    base = ["user/-/state/com.google/reading-list"]
    base = if is_read, do: ["user/-/state/com.google/read" | base], else: base
    base = if is_star, do: ["user/-/state/com.google/starred" | base], else: base
    base = if feed, do: [Ids.feed_stream_id(feed) | base], else: base

    if is_binary(category_name) and category_name != "" do
      [Ids.label_stream_id(category_name) | base]
    else
      base
    end
  end

  defp unix(nil), do: nil
  defp unix(%DateTime{} = dt), do: DateTime.to_unix(dt)

  defp unix(%NaiveDateTime{} = ndt),
    do: ndt |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix()
end
