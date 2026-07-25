defmodule Earss.Feeds.Fetcher do
  @moduledoc """
  Orchestrates one refresh cycle: HTTP → parse → upsert → update feed.

  Interval adaptation and `next_fetch_at` are delegated to
  `Earss.FeedScheduler`.
  """

  alias Earss.FeedScheduler
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

  Options:

    * `:force` — when true, skip conditional GET validators and content-hash
      short-circuit so the body is always re-parsed (used by Admin manual refresh).
  """
  @spec refresh(Feed.t() | term(), keyword()) ::
          refresh_ok() | refresh_error() | {:error, :not_found}
  def refresh(feed_or_id, opts \\ [])

  def refresh(%Feed{} = feed, opts) when is_list(opts) do
    do_refresh(feed, opts)
  end

  def refresh(id, opts) when is_list(opts) do
    case Feeds.get_feed(id) do
      nil -> {:error, :not_found}
      feed -> do_refresh(feed, opts)
    end
  end

  defp do_refresh(%Feed{} = feed, opts) do
    customs = FeedScheduler.load_custom_intervals(feed.id)
    force? = Keyword.get(opts, :force, false)

    http_opts =
      if force? do
        []
      else
        [etag: feed.etag, last_modified: feed.last_modified]
      end

    case HTTP.get(feed.link, http_opts) do
      {:ok, :not_modified} ->
        with {:ok, _feed} <-
               touch_not_modified(feed, customs, []) do
          {:ok, :not_modified}
        end

      {:ok, %{body: body, etag: etag, last_modified: last_modified}} ->
        hash = content_hash(body)

        if not force? and hash != nil and hash == feed.last_fetched_content_hash do
          with {:ok, _feed} <-
                 touch_not_modified(feed, customs,
                   etag: etag,
                   last_modified: last_modified,
                   hash: hash
                 ) do
            {:ok, :not_modified}
          end
        else
          ingest_body(feed, body, etag, last_modified, hash, customs)
        end

      {:error, {:http, reason}} ->
        _ = mark_error(feed, format_error(reason), customs)
        {:error, {:http, reason}}
    end
  end

  defp ingest_body(feed, body, etag, last_modified, hash, customs) do
    case Parser.parse(body) do
      {:ok, %{feed: feed_meta, entries: entries, feed_type: feed_type}} ->
        case Feeds.upsert_entries(feed, entries) do
          {:ok, %{entries: upserted_entries, skipped: skipped}} ->
            # Heuristic: if every upserted row is brand-new, treat as new content;
            # also treat any successful parse with items as new content for interval
            # adaptation when content hash changed (we already branched on hash).
            outcome =
              if upserted_entries == [] do
                :success_no_content
              else
                :success_new_content
              end

            case commit_success(
                   feed,
                   feed_meta,
                   feed_type,
                   etag,
                   last_modified,
                   hash,
                   upserted_entries,
                   outcome,
                   customs
                 ) do
              {:ok, feed} ->
                {:ok, %{upserted: length(upserted_entries), skipped: skipped, feed: feed}}

              {:error, _} = err ->
                err
            end

          {:error, %Ecto.Changeset{} = changeset} ->
            _ = mark_error(feed, "upsert failed", customs)
            {:error, changeset}
        end

      {:error, {:parse, reason}} ->
        _ = mark_error(feed, format_error(reason), customs)
        {:error, {:parse, reason}}
    end
  end

  defp commit_success(
         feed,
         feed_meta,
         feed_type,
         etag,
         last_modified,
         hash,
         upserted_entries,
         outcome,
         customs
       ) do
    now = utc_now()
    schedule = FeedScheduler.schedule_attrs(feed, outcome, now: now, custom_intervals: customs)

    attrs =
      schedule
      |> Map.merge(%{
        last_fetched_at: now,
        unchanged_fetch_count:
          if(outcome == :success_new_content, do: 0, else: feed.unchanged_fetch_count + 1),
        etag: etag || feed.etag,
        last_modified: last_modified || feed.last_modified,
        last_fetched_content_hash: hash,
        feed_type: feed_type
      })
      |> maybe_put(:title, feed_meta[:title] || feed_meta["title"])
      |> maybe_put(:description, feed_meta[:description] || feed_meta["description"])
      |> maybe_put(:site_url, feed_meta[:site_url] || feed_meta["site_url"])
      |> then(fn attrs ->
        if outcome == :success_new_content do
          Map.put(attrs, :last_new_entry_at, now)
        else
          attrs
        end
      end)

    # silence unused if empty list path
    _ = upserted_entries

    Feeds.update_feed(feed, attrs)
  end

  defp touch_not_modified(feed, customs, opts) do
    now = utc_now()

    schedule =
      FeedScheduler.schedule_attrs(feed, :success_no_content, now: now, custom_intervals: customs)

    attrs =
      schedule
      |> Map.merge(%{
        last_fetched_at: now,
        unchanged_fetch_count: feed.unchanged_fetch_count + 1
      })
      |> maybe_put(:etag, Keyword.get(opts, :etag))
      |> maybe_put(:last_modified, Keyword.get(opts, :last_modified))
      |> maybe_put(:last_fetched_content_hash, Keyword.get(opts, :hash))

    Feeds.update_feed(feed, attrs)
  end

  defp mark_error(feed, message, customs) do
    now = utc_now()

    schedule =
      FeedScheduler.schedule_attrs(feed, :error,
        now: now,
        custom_intervals: customs,
        error_count: feed.error_count
      )

    attrs =
      Map.merge(schedule, %{
        last_fetched_at: now,
        last_error: truncate_error(message)
      })

    Feeds.update_feed(feed, attrs)
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
