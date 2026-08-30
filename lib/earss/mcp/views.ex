defmodule Earss.MCP.Views do
  @moduledoc """
  Renders entries and feeds for agent consumption.

  The shaping here exists for one reason: an agent's context window is the
  scarce resource. A feed page of twenty full articles is tens of thousands
  of tokens and will either be truncated by the client or crowd out
  everything else the model needed. So:

    * **lists carry excerpts, not bodies** — `entry_list/2` truncates to
      `:excerpt_chars` and reports `truncated`, and the agent fetches the
      full text with `entry_get` for the one or two it cares about
    * **state is inlined** — read/starred/translation/tts sit on the row so
      the agent does not need a follow-up call per entry to know what it is
      looking at
    * **HTML is stripped** — entry bodies are stored HTML; models work far
      better on text, and the tags are mostly noise for a summary

  Excerpting is deliberately byte-based and naive. It is a display concern,
  not a parsing one, and it must never fail on malformed markup.
  """

  @default_excerpt_chars 500
  @max_excerpt_chars 5_000

  @doc """
  Render one timeline row for a list response.
  """
  @spec entry_summary(map(), keyword()) :: map()
  def entry_summary(%{entry: entry} = row, opts \\ []) do
    limit = excerpt_limit(opts)

    body =
      entry
      |> body_text()
      |> excerpt(limit)

    %{
      id: entry.id,
      feed_id: entry.feed_id,
      title: entry.title,
      author: entry.author,
      link: entry.link,
      published_at: entry.published_at,
      is_read: row.is_read,
      is_starred: row.is_star,
      excerpt: body.text,
      truncated: body.truncated
    }
  end

  @doc """
  Render one entry in full, including the cleaned body.
  """
  @spec entry_detail(Earss.Feeds.Entry.t()) :: map()
  def entry_detail(entry) do
    %{
      id: entry.id,
      feed_id: entry.feed_id,
      title: entry.title,
      author: entry.author,
      link: entry.link,
      guid: entry.guid,
      published_at: entry.published_at,
      text: body_text(entry)
    }
  end

  @doc """
  Render a subscription with the fields an agent acts on.
  """
  @spec subscription_summary(map()) :: map()
  def subscription_summary(sub) do
    feed = sub.feed

    %{
      id: sub.id,
      feed_id: feed && feed.id,
      title: Earss.Admin.Helpers.display_title(sub),
      feed_link: feed && feed.link,
      category_id: sub.category_id,
      custom_title: sub.custom_title,
      is_hidden: sub.is_hidden,
      unread_count: sub.unread_count,
      feed: feed && feed_summary(feed)
    }
    |> reject_nils()
  end

  @doc """
  Render feed health and scheduling state.
  """
  @spec feed_summary(Earss.Feeds.Feed.t()) :: map()
  def feed_summary(feed) do
    %{
      id: feed.id,
      link: feed.link,
      title: feed.title,
      feed_type: feed.feed_type,
      adapter_id: feed.adapter_id,
      is_active: feed.is_active,
      error_count: feed.error_count,
      last_error: feed.last_error,
      last_fetched_at: feed.last_fetched_at,
      next_fetch_at: feed.next_fetch_at,
      refresh_interval: feed.refresh_interval,
      translate_to: feed.translate_to
    }
    |> reject_nils()
  end

  ## Internal

  # Summary first, content second: many feeds put a real summary in one and
  # a full body in the other, and the summary is the better excerpt source.
  # Falling back to no text at all is fine — an entry can legitimately have
  # neither.
  defp body_text(entry) do
    entry
    |> raw_body()
    |> strip_html()
  end

  defp raw_body(%{summary: s}) when is_binary(s) and s != "", do: s
  defp raw_body(%{content: c}) when is_binary(c), do: c
  defp raw_body(_), do: ""

  # Entry bodies are stored HTML. Models read prose far better than markup,
  # and the tags are noise in an excerpt — but stripping must never fail on
  # malformed input, hence the rescue: Floki raises on some fragments and a
  # rendering concern should not take down a tool call.
  defp strip_html(text) do
    case Floki.parse_fragment(text) do
      {:ok, tree} -> tree |> Floki.text(sep: " ") |> collapse_whitespace()
      _ -> text
    end
  rescue
    _ -> text
  end

  defp collapse_whitespace(text), do: text |> String.replace(~r/\s+/, " ") |> String.trim()

  # A JSON null arrives as a present key with a nil value, so Keyword.get/3
  # would hand back nil instead of the default — and a nil limit disables
  # truncation entirely, which is the one outcome that defeats the point of
  # an excerpt. Fall back explicitly.
  defp excerpt_limit(opts) do
    case Keyword.get(opts, :excerpt_chars) do
      n when is_integer(n) and n > 0 -> min(n, @max_excerpt_chars)
      _ -> @default_excerpt_chars
    end
  end

  defp excerpt(text, limit) when is_integer(limit) and limit > 0 do
    if String.length(text) > limit do
      %{text: String.slice(text, 0, limit) <> "…", truncated: true}
    else
      %{text: text, truncated: false}
    end
  end

  defp reject_nils(map), do: Enum.reject(map, fn {_k, v} -> is_nil(v) end) |> Map.new()
end
