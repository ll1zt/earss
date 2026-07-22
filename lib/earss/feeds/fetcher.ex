defmodule Earss.Feeds.Fetcher do
  @moduledoc """
  Orchestrates one refresh cycle: HTTP → parse → upsert → update feed.

  Adaptive interval tuning belongs to the scheduler phase; this module only
  advances `next_fetch_at` by the current `refresh_interval` (or a simple
  error backoff multiplier).
  """

  alias Earss.Feeds
  alias Earss.Feeds.Feed
  alias Earss.Feeds.HTTP
  alias Earss.Feeds.Parser

  @type refresh_ok ::
          {:ok, :not_modified}
          | {:ok, %{upserted: non_neg_integer(), skipped: non_neg_integer(), feed: Feed.t()}}

  @type refresh_error ::
          {:error, {:http, term()}}
          | {:error, {:parse, term()}}
          | {:error, Ecto.Changeset.t()}

  @doc """
  Refresh a feed by id or struct.
  """
  @spec refresh(Feed.t() | term()) :: refresh_ok() | refresh_error() | {:error, :not_found}
  def refresh(%Feed{} = feed) do
    do_refresh(feed)
  end

  def refresh(id) do
    case Feeds.get_feed(id) do
      nil -> {:error, :not_found}
      feed -> do_refresh(feed)
    end
  end

  defp do_refresh(%Feed{} = feed) do
    case HTTP.get(feed.link, etag: feed.etag, last_modified: feed.last_modified) do
      {:ok, :not_modified} ->
        with {:ok, _feed} <- touch_not_modified(feed), do: {:ok, :not_modified}

      {:ok, %{body: body, etag: etag, last_modified: last_modified}} ->
        hash = content_hash(body)

        if hash != nil and hash == feed.last_fetched_content_hash do
          with {:ok, _feed} <-
                 touch_not_modified(feed, etag: etag, last_modified: last_modified, hash: hash) do
            {:ok, :not_modified}
          end
        else
          ingest_body(feed, body, etag, last_modified, hash)
        end

      {:error, {:http, reason}} ->
        _ = mark_error(feed, format_error(reason))
        {:error, {:http, reason}}
    end
  end

  defp ingest_body(feed, body, etag, last_modified, hash) do
    case Parser.parse(body) do
      {:ok, %{feed: feed_meta, entries: entries, feed_type: feed_type}} ->
        case Feeds.upsert_entries(feed, entries) do
          {:ok, %{entries: upserted_entries, skipped: skipped}} ->
            case commit_success(feed, feed_meta, feed_type, etag, last_modified, hash, upserted_entries) do
              {:ok, feed} ->
                {:ok, %{upserted: length(upserted_entries), skipped: skipped, feed: feed}}

              {:error, _} = err ->
                err
            end

          {:error, %Ecto.Changeset{} = changeset} ->
            _ = mark_error(feed, "upsert failed")
            {:error, changeset}
        end

      {:error, {:parse, reason}} ->
        _ = mark_error(feed, format_error(reason))
        {:error, {:parse, reason}}
    end
  end

  defp commit_success(feed, feed_meta, feed_type, etag, last_modified, hash, upserted_entries) do
    now = utc_now()
    has_entries? = upserted_entries != []

    attrs =
      %{
        last_fetched_at: now,
        next_fetch_at: next_fetch_at(feed, now, :success),
        error_count: 0,
        last_error: nil,
        unchanged_fetch_count: if(has_entries?, do: 0, else: feed.unchanged_fetch_count + 1),
        etag: etag || feed.etag,
        last_modified: last_modified || feed.last_modified,
        last_fetched_content_hash: hash,
        feed_type: feed_type
      }
      |> maybe_put(:title, feed_meta[:title] || feed_meta["title"])
      |> maybe_put(:description, feed_meta[:description] || feed_meta["description"])
      |> maybe_put(:site_url, feed_meta[:site_url] || feed_meta["site_url"])
      |> then(fn attrs ->
        if has_entries? do
          Map.put(attrs, :last_new_entry_at, now)
        else
          attrs
        end
      end)

    Feeds.update_feed(feed, attrs)
  end

  defp touch_not_modified(feed, opts \\ []) do
    now = utc_now()

    attrs = %{
      last_fetched_at: now,
      next_fetch_at: next_fetch_at(feed, now, :success),
      error_count: 0,
      last_error: nil,
      unchanged_fetch_count: feed.unchanged_fetch_count + 1
    }

    attrs =
      attrs
      |> maybe_put(:etag, Keyword.get(opts, :etag))
      |> maybe_put(:last_modified, Keyword.get(opts, :last_modified))
      |> maybe_put(:last_fetched_content_hash, Keyword.get(opts, :hash))

    Feeds.update_feed(feed, attrs)
  end

  defp mark_error(feed, message) do
    now = utc_now()
    error_count = feed.error_count + 1

    attrs = %{
      last_fetched_at: now,
      next_fetch_at: next_fetch_at(feed, now, {:error, error_count}),
      error_count: error_count,
      last_error: truncate_error(message)
    }

    # Simple circuit breaker threshold (scheduler phase may refine).
    attrs =
      if error_count >= 5 do
        Map.put(attrs, :is_active, false)
      else
        attrs
      end

    Feeds.update_feed(feed, attrs)
  end

  defp next_fetch_at(%Feed{refresh_interval: interval}, now, :success) do
    DateTime.add(now, interval * 60, :second)
  end

  defp next_fetch_at(%Feed{refresh_interval: interval}, now, {:error, error_count}) do
    factor = min(Integer.pow(2, max(error_count - 1, 0)), 32)
    DateTime.add(now, interval * 60 * factor, :second)
  end

  defp content_hash(body) when is_binary(body) do
    :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_error(%{__exception__: true} = e), do: Exception.message(e)
  defp format_error(reason), do: inspect(reason)

  defp truncate_error(msg) when is_binary(msg) and byte_size(msg) > 1000 do
    binary_part(msg, 0, 1000) <> "…"
  end

  defp truncate_error(msg), do: msg

  defp utc_now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
