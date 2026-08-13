defmodule Earss.API.Views do
  @moduledoc false

  def user(user) do
    %{
      id: Map.get(user, :id),
      username: user.username,
      user_type: user.user_type,
      is_active: Map.get(user, :is_active, true)
    }
  end

  def category(cat) do
    %{
      id: cat.id,
      name: cat.name,
      position: cat.position,
      user_id: cat.user_id
    }
  end

  def feed(feed) when is_map(feed) do
    %{
      id: feed.id,
      link: feed.link,
      title: feed.title,
      site_url: feed.site_url,
      feed_type: feed.feed_type,
      is_active: feed.is_active,
      last_fetched_at: feed.last_fetched_at,
      next_fetch_at: feed.next_fetch_at
    }
  end

  def subscription(sub) do
    base = %{
      id: sub.id,
      user_id: sub.user_id,
      feed_id: sub.feed_id,
      category_id: sub.category_id,
      custom_title: sub.custom_title,
      custom_refresh_interval: sub.custom_refresh_interval,
      is_hidden: sub.is_hidden,
      feed: if(Ecto.assoc_loaded?(sub.feed) and sub.feed, do: feed(sub.feed), else: nil),
      category:
        if(Ecto.assoc_loaded?(sub.category) and sub.category,
          do: category(sub.category),
          else: nil
        )
    }

    case Map.get(sub, :unread_count) do
      nil -> base
      n -> Map.put(base, :unread_count, n)
    end
  end

  def entry_row(row), do: entry_row(row, nil)

  def entry_row(%{entry: entry} = row, translation) do
    base = %{
      id: entry.id,
      feed_id: entry.feed_id,
      link: entry.link,
      guid: entry.guid,
      title: entry.title,
      author: entry.author,
      summary: entry.summary,
      content: entry.content,
      published_at: entry.published_at,
      is_read: row.is_read,
      is_star: row.is_star,
      subscription_id: row.subscription_id,
      custom_title: row.custom_title
    }

    # Goal 2: translated view via ?translate_to=zh (keys only present when a
    # stored translation exists; original fields stay untouched).
    case translation do
      nil ->
        base

      %{title: t, summary: s, content: c} ->
        base
        |> maybe_put(:title_translated, t)
        |> maybe_put(:summary_translated, s)
        |> maybe_put(:content_translated, c)
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
