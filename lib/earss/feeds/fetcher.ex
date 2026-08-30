defmodule Earss.Feeds.Fetcher do
  @moduledoc """
  Orchestrates one refresh cycle via a source adapter → upsert → update feed.

  Interval adaptation and `next_fetch_at` are delegated to
  `Earss.FeedScheduler`. Adapters implement `Earss.Source.Adapter`
  (native RSS/Atom/JSON or plugins).
  """

  require Logger

  alias Earss.FeedScheduler
  alias Earss.Feeds
  alias Earss.Feeds.Feed
  alias Earss.Source.Resolver
  alias Earss.Enrichment

  @type refresh_ok ::
          {:ok, :not_modified}
          | {:ok, %{upserted: non_neg_integer(), skipped: non_neg_integer(), feed: Feed.t()}}

  @type refresh_error ::
          {:error, {:http, term()}}
          | {:error, {:parse, term()}}
          | {:error, {:adapter, term()}}
          | {:error, Ecto.Changeset.t()}

  @doc """
  Refresh a feed by id or struct.

  Options:

    * `:force` — when true, adapters should skip conditional short-circuits
      (used by Admin manual refresh).
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
    start = System.monotonic_time()
    result = do_refresh_inner(feed, opts)
    emit_fetch(feed, start, result)
    result
  end

  # Containers (feed_type = "manual") have no source to crawl: they exist to
  # own content an agent collected. Refusing here is the last line of defence
  # behind FeedScheduler.list_due_feeds/2, which already skips them, so an
  # explicit refresh — from the admin UI or an MCP tool — cannot turn one into
  # a failing fetch either.
  defp do_refresh_inner(%Feed{feed_type: "manual"} = _feed, _opts) do
    {:error, {:adapter, :not_fetchable}}
  end

  defp do_refresh_inner(%Feed{} = feed, opts) do
    customs = FeedScheduler.load_custom_intervals(feed.id)
    force? = Keyword.get(opts, :force, false)
    adapter = Resolver.adapter_module(feed)

    case safe_fetch(adapter, feed, force: force?) do
      {:ok, :not_modified} ->
        with {:ok, _feed} <- touch_not_modified(feed, customs, []) do
          {:ok, :not_modified}
        end

      {:ok, payload} when is_map(payload) ->
        ingest_payload(feed, payload, customs)

      {:error, {:http, reason}} ->
        _ = mark_error(feed, format_error(reason), customs)
        {:error, {:http, reason}}

      {:error, {:parse, reason}} ->
        _ = mark_error(feed, format_error(reason), customs)
        {:error, {:parse, reason}}

      {:error, reason} ->
        _ = mark_error(feed, format_error(reason), customs)
        {:error, {:adapter, reason}}
    end
  end

  # Telemetry: one [:earss, :feed, :fetch] event per refresh, outcome-coded
  # so the metrics store can rank failures and latency without touching the
  # control flow above.
  defp emit_fetch(feed, start, result) do
    {outcome, measurements} =
      case result do
        {:ok, :not_modified} -> {:not_modified, %{}}
        {:ok, %{upserted: u, skipped: s}} -> {:success, %{upserted: u, skipped: s}}
        {:error, {:http, _}} -> {:http_error, %{}}
        {:error, {:parse, _}} -> {:parse_error, %{}}
        {:error, {:adapter, _}} -> {:adapter_error, %{}}
        {:error, _} -> {:error, %{}}
      end

    :telemetry.execute(
      Earss.Telemetry.event_feed_fetch(),
      Map.put(measurements, :duration, System.monotonic_time() - start),
      %{
        feed_id: feed.id,
        link: feed.link,
        adapter_id: feed.adapter_id,
        outcome: outcome
      }
    )
  end

  defp safe_fetch(adapter, feed, opts) do
    adapter.fetch(feed, opts)
  rescue
    e ->
      Logger.error("source adapter #{inspect(adapter)} crashed: #{Exception.message(e)}")
      {:error, {:adapter_exception, Exception.message(e)}}
  catch
    kind, reason ->
      Logger.error("source adapter #{inspect(adapter)} #{kind}: #{inspect(reason)}")
      {:error, {:adapter_throw, kind, reason}}
  end

  @doc """
  Public ingest entry: same as the private refresh-time path, exposed so a
  backfill can turn a fetched payload into rows with identical side effects.

  `opts` is passed to `FeedScheduler.load_custom_intervals/2` for the feed's
  per-subscription interval overrides.
  """
  @spec ingest_payload(Earss.Feeds.Feed.t(), map(), keyword()) ::
          {:ok,
           %{upserted: non_neg_integer(), skipped: non_neg_integer(), feed: Earss.Feeds.Feed.t()}}
          | {:error, term()}
  def ingest_payload(feed, payload, _opts \\ []) do
    customs = FeedScheduler.load_custom_intervals(feed.id)
    do_ingest_payload(feed, payload, customs)
  end

  defp do_ingest_payload(feed, payload, customs) do
    entries = Map.get(payload, :entries) || Map.get(payload, "entries") || []
    feed_meta = Map.get(payload, :feed) || Map.get(payload, "feed") || %{}
    feed_type = Map.get(payload, :feed_type) || Map.get(payload, "feed_type")
    etag = Map.get(payload, :etag) || Map.get(payload, "etag")
    last_modified = Map.get(payload, :last_modified) || Map.get(payload, "last_modified")
    hash = Map.get(payload, :content_hash) || Map.get(payload, "content_hash")
    cursor = Map.get(payload, :cursor) || Map.get(payload, "cursor")

    case Feeds.upsert_entries(feed, entries) do
      {:ok, %{entries: upserted_entries, skipped: skipped}} ->
        _ = maybe_translate_new_entries(feed, upserted_entries)

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
               cursor,
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
  end

  # Goal 2 translation hook: newly upserted entries of translated feeds are
  # flagged pending (hidden from protocol clients) and translated. Best-effort
  # — provider errors, missing translators or crashes must never fail the
  # refresh cycle; pending entries are retried by the PendingWorker.
  #
  # Enrichment runs **asynchronously** (default) under the
  # Enrichment.TaskSupervisor: a provider call chain (retries x model
  # fallback x timeout) can take minutes, and the poller kills refresh tasks
  # after POLLER_TIMEOUT_MS (60s default) — a synchronous hook would be
  # killed mid-translation, leaving the feed due forever (last_fetched_at /
  # next_fetch_at never updated) and its entries hidden pending. Tests inject
  # `hook_runner: :sync` (config :earss, :translate) for determinism under
  # the Ecto sandbox.
  defp maybe_translate_new_entries(_feed, []), do: :ok

  defp maybe_translate_new_entries(feed, entries) do
    _ = Enrichment.mark_pending(feed, entries)

    runner =
      :earss
      |> Application.get_env(:translate, [])
      |> Keyword.get(:hook_runner, :async)

    case runner do
      :sync -> run_translate(feed, entries)
      _ -> async_translate(feed, entries)
    end

    :ok
  end

  defp async_translate(feed, entries) do
    _ =
      Task.Supervisor.start_child(Earss.Enrichment.TaskSupervisor, fn ->
        run_translate(feed, entries)
      end)

    :ok
  end

  defp run_translate(feed, entries) do
    try do
      case Enrichment.enrich_new_entries(feed, entries) do
        {:ok, n} when n > 0 ->
          Logger.info("translated #{n} new entr(y/ies) for feed #{feed.id}")

        _ ->
          :ok
      end
    rescue
      e ->
        Logger.error("translation hook failed for feed #{feed.id}: #{Exception.message(e)}")
        :ok
    catch
      _, _ -> :ok
    end
  end

  defp commit_success(
         feed,
         feed_meta,
         feed_type,
         etag,
         last_modified,
         hash,
         cursor,
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
        last_fetched_content_hash: hash || feed.last_fetched_content_hash
      })
      |> maybe_put(:title, feed_meta[:title] || feed_meta["title"])
      |> maybe_put(:description, feed_meta[:description] || feed_meta["description"])
      |> maybe_put(:site_url, feed_meta[:site_url] || feed_meta["site_url"])
      |> maybe_put_feed_type(feed, feed_type)
      |> maybe_put_cursor(feed, cursor)
      |> then(fn attrs ->
        if outcome == :success_new_content do
          Map.put(attrs, :last_new_entry_at, now)
        else
          attrs
        end
      end)

    Feeds.update_feed(feed, attrs)
  end

  defp maybe_put_feed_type(attrs, feed, feed_type) do
    cond do
      is_binary(feed_type) and feed_type != "" ->
        # Do not overwrite a plugin feed_type with nil from payloads that omit it
        Map.put(attrs, :feed_type, feed_type)

      Map.get(feed, :feed_type) == "plugin" ->
        attrs

      true ->
        attrs
    end
  end

  defp maybe_put_cursor(attrs, feed, cursor) when is_map(cursor) do
    if Map.has_key?(feed, :adapter_cursor) or Map.has_key?(feed, "adapter_cursor") do
      Map.put(attrs, :adapter_cursor, cursor)
    else
      attrs
    end
  end

  defp maybe_put_cursor(attrs, _feed, _), do: attrs

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

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_error(%{__exception__: true} = e), do: Exception.message(e)
  defp format_error({:http, reason}), do: format_error(reason)
  defp format_error({:parse, reason}), do: format_error(reason)
  defp format_error(reason), do: inspect(reason)

  defp truncate_error(msg) when is_binary(msg) and byte_size(msg) > 1000 do
    binary_part(msg, 0, 1000) <> "…"
  end

  defp truncate_error(msg), do: msg

  defp utc_now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
