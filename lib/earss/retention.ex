defmodule Earss.Retention do
  @moduledoc """
  Data retention / cleanup jobs (lifecycle D3 / D6).

  Run order is fixed: Level A → Level B → Level C.

  Options common to all public functions:

    * `:now` — `DateTime` (default utc now)
    * `:batch_size` — max rows per delete batch (default 1000)
    * `:dry_run` — when true, only count matching rows (no deletes)
    * `:max_batches` — safety cap on loop iterations (default 1000)
  """

  import Ecto.Query, warn: false

  require Logger

  alias Earss.Repo
  alias Earss.Feeds.Feed
  alias Earss.Feeds.Entry
  alias Earss.Reader.EntryState

  @type level_result :: %{deleted: non_neg_integer(), dry_run: boolean()}
  @type run_result :: %{
          states: level_result(),
          entries: level_result(),
          feeds: level_result()
        }

  @doc """
  Run Level A, then B, then C. Returns per-level counts.
  """
  @spec run_all(keyword()) :: run_result()
  def run_all(opts \\ []) do
    start = System.monotonic_time()
    result = do_run_all(opts)

    :telemetry.execute(
      Earss.Telemetry.event_retention_run(),
      %{
        duration: System.monotonic_time() - start,
        states: result.states.deleted,
        entries: result.entries.deleted,
        feeds: result.feeds.deleted
      },
      %{dry_run: result.states.dry_run}
    )

    result
  end

  defp do_run_all(opts) do
    states = purge_expired_states(opts)
    entries = purge_reclaimable_entries(opts)
    feeds = purge_unsubscribed_feeds(opts)

    result = %{states: states, entries: entries, feeds: feeds}

    Logger.info(
      "Retention finished dry_run=#{states.dry_run} states=#{states.deleted} entries=#{entries.deleted} feeds=#{feeds.deleted}"
    )

    result
  end

  @doc """
  Level A — delete expired read, unstarred entry states.
  """
  @spec purge_expired_states(keyword()) :: level_result()
  def purge_expired_states(opts \\ []) do
    opts = normalize_opts(opts)
    days = retention_days(:read_state_days, 90)
    cutoff = DateTime.add(opts.now, -days * 86_400, :second)

    filter = fn query ->
      from(st in query,
        where: st.is_read == true,
        where: st.is_star == false,
        where: not is_nil(st.read_at),
        where: st.read_at < ^cutoff
      )
    end

    purge_schema(EntryState, filter, opts, "entry_states")
  end

  @doc """
  Level B — delete reclaimable entries (run after Level A).

  Deletes entries older than `entry_days` that have:

    * no starred state
    * no explicit unread state (`is_read = false`)

  Entries with no states are deleted only when past the retention window.
  """
  @spec purge_reclaimable_entries(keyword()) :: level_result()
  def purge_reclaimable_entries(opts \\ []) do
    opts = normalize_opts(opts)
    days = retention_days(:entry_days, 180)
    cutoff = DateTime.add(opts.now, -days * 86_400, :second)

    filter = fn query ->
      from(e in query,
        where: e.inserted_at < ^cutoff,
        where:
          fragment(
            "NOT EXISTS (SELECT 1 FROM entry_states st WHERE st.entry_id = ? AND st.is_star = TRUE)",
            e.id
          ),
        where:
          fragment(
            "NOT EXISTS (SELECT 1 FROM entry_states st WHERE st.entry_id = ? AND st.is_read = FALSE)",
            e.id
          )
      )
    end

    purge_schema(Entry, filter, opts, "entries")
  end

  @doc """
  Level C — delete feeds with no subscribers past the grace window.
  """
  @spec purge_unsubscribed_feeds(keyword()) :: level_result()
  def purge_unsubscribed_feeds(opts \\ []) do
    opts = normalize_opts(opts)
    days = retention_days(:unsubscribed_feed_days, 30)
    cutoff = DateTime.add(opts.now, -days * 86_400, :second)

    filter = fn query ->
      from(f in query,
        where: not is_nil(f.last_unsubscribed_at),
        where: f.last_unsubscribed_at < ^cutoff,
        where: fragment("NOT EXISTS (SELECT 1 FROM subscriptions s WHERE s.feed_id = ?)", f.id)
      )
    end

    purge_schema(Feed, filter, opts, "feeds")
  end

  ## Internal

  defp purge_schema(schema, filter_fun, opts, label) do
    filtered = filter_fun.(from(r in schema))

    if opts.dry_run do
      count = Repo.aggregate(filtered, :count)
      Logger.info("Retention dry_run #{label}: would delete #{count}")
      %{deleted: count, dry_run: true}
    else
      total = delete_batches(schema, filter_fun, opts, 0, 0)
      Logger.info("Retention deleted #{total} from #{label}")
      %{deleted: total, dry_run: false}
    end
  end

  defp delete_batches(_schema, _filter_fun, opts, batch_idx, total)
       when batch_idx >= opts.max_batches do
    Logger.warning("Retention hit max_batches=#{opts.max_batches}, deleted so far=#{total}")
    total
  end

  defp delete_batches(schema, filter_fun, opts, batch_idx, total) do
    ids =
      schema
      |> then(&from(r in &1))
      |> filter_fun.()
      |> select([r], r.id)
      |> limit(^opts.batch_size)
      |> Repo.all()

    case ids do
      [] ->
        total

      ids ->
        {n, _} = from(r in schema, where: r.id in ^ids) |> Repo.delete_all()
        delete_batches(schema, filter_fun, opts, batch_idx + 1, total + n)
    end
  end

  defp normalize_opts(opts) do
    %{
      now: Keyword.get(opts, :now, utc_now()),
      batch_size: Keyword.get(opts, :batch_size, default_batch_size()),
      dry_run: Keyword.get(opts, :dry_run, false),
      max_batches: Keyword.get(opts, :max_batches, 1000)
    }
  end

  defp default_batch_size do
    Application.get_env(:earss, :retention_poller, [])
    |> Keyword.get(:batch_size, 1000)
  end

  defp retention_days(key, default) do
    Application.get_env(:earss, :retention, [])
    |> Keyword.get(key, default)
  end

  defp utc_now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
