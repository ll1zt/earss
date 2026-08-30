defmodule Earss.Retention do
  @moduledoc """
  Data retention / cleanup jobs (lifecycle D3 / D6).

  Run order is fixed: Level A → Level B → Level C → Level D → Level E.
  Levels D and E cover the TTS pipeline (docs/tts.md): expired `ready`
  rows plus their audio files, then orphaned audio files on disk.

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
  alias Earss.TTS.Request

  @type level_result :: %{deleted: non_neg_integer(), dry_run: boolean()}
  @type run_result :: %{
          states: level_result(),
          entries: level_result(),
          feeds: level_result(),
          tts_requests: level_result(),
          tts_audio_files: level_result()
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
        feeds: result.feeds.deleted,
        tts_requests: result.tts_requests.deleted,
        tts_audio_files: result.tts_audio_files.deleted
      },
      %{dry_run: result.states.dry_run}
    )

    result
  end

  defp do_run_all(opts) do
    states = purge_expired_states(opts)
    entries = purge_reclaimable_entries(opts)
    feeds = purge_unsubscribed_feeds(opts)
    tts_requests = purge_expired_tts_requests(opts)
    tts_audio_files = purge_orphan_audio_files(opts)

    result = %{
      states: states,
      entries: entries,
      feeds: feeds,
      tts_requests: tts_requests,
      tts_audio_files: tts_audio_files
    }

    Logger.info(
      "Retention finished dry_run=#{states.dry_run} states=#{states.deleted} entries=#{entries.deleted} feeds=#{feeds.deleted} tts_requests=#{tts_requests.deleted} tts_audio_files=#{tts_audio_files.deleted}"
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

  @doc """
  Level D — delete expired `ready` TTS requests together with their audio
  files (run after Level C, before Level E).

  Only `ready` rows are targeted: `requested`/`processing` are pending or
  in-flight work and `failed` rows are operator evidence. Rows are deleted
  first, then the files — the podcast audio endpoint requires a `ready` row
  to serve, so a removed row makes the media 404 immediately even if the
  file delete fails (Level E sweeps leftovers on a later run).

  Disabled when `tts_audio_days` is `nil` (the retention default).

  Re-synthesizing after expiry is allowed by design: with the row gone the
  listen control can record a fresh request.
  """
  @spec purge_expired_tts_requests(keyword()) :: level_result()
  def purge_expired_tts_requests(opts \\ []) do
    opts = normalize_opts(opts)

    case tts_audio_days() do
      nil ->
        Logger.info("Retention tts_requests: disabled (tts_audio_days not set)")
        %{deleted: 0, dry_run: opts.dry_run}

      days ->
        cutoff = DateTime.add(opts.now, -days * 86_400, :second)

        filter = fn query ->
          from(r in query,
            where: r.state == :ready,
            where: r.updated_at < ^cutoff,
            where: not is_nil(r.audio_path)
          )
        end

        files =
          from(r in Request)
          |> filter.()
          |> select([r], r.audio_path)
          |> Repo.all()

        result = purge_schema(Request, filter, opts, "tts_requests")

        unless opts.dry_run do
          Enum.each(files, &delete_audio_file(&1, "tts retention"))
        end

        result
    end
  end

  @doc """
  Level E — sweep orphaned audio files (run last).

  A file is orphaned when no `tts_requests` row references it in a live
  state (`requested`/`processing`/`ready`) and its mtime is older than
  `tts_orphan_grace_hours`. The grace window covers the worker's own
  write-then-mark-ready span, so a file being synthesized right now is
  never swept. Files that do not match the worker's naming whitelist are
  left alone (not ours to judge).

  Covers cascade orphans (an entry purged in Level B deletes its
  `tts_requests` row but not the file), worker crash leftovers and any
  other drift.
  """
  @spec purge_orphan_audio_files(keyword()) :: level_result()
  def purge_orphan_audio_files(opts \\ []) do
    opts = normalize_opts(opts)
    dir = tts_audio_dir()

    if is_binary(dir) do
      grace_secs = tts_orphan_grace_hours() * 3_600
      cutoff = DateTime.add(opts.now, -grace_secs, :second)

      live_paths = MapSet.new(live_audio_paths())

      dir
      |> list_audio_files()
      |> Enum.filter(fn {filename, mtime} ->
        filename not in live_paths and DateTime.compare(mtime, cutoff) == :lt
      end)
      |> then(fn orphans ->
        if opts.dry_run do
          Logger.info("Retention dry_run tts_audio_files: would delete #{length(orphans)}")
          %{deleted: length(orphans), dry_run: true}
        else
          Enum.each(orphans, fn {filename, _mtime} ->
            delete_audio_file(filename, "orphan sweep")
          end)

          Logger.info("Retention deleted #{length(orphans)} orphaned audio files")
          %{deleted: length(orphans), dry_run: false}
        end
      end)
    else
      %{deleted: 0, dry_run: opts.dry_run}
    end
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

  # nil disables Level D/E row expiry (opt-in via EARSS_TTS_AUDIO_RETENTION_DAYS).
  defp tts_audio_days do
    Application.get_env(:earss, :retention, [])
    |> Keyword.get(:tts_audio_days)
  end

  defp tts_orphan_grace_hours do
    Application.get_env(:earss, :retention, [])
    |> Keyword.get(:tts_orphan_grace_hours, 24)
  end

  defp tts_audio_dir do
    case Application.get_env(:earss, :tts) do
      kw when is_list(kw) -> Keyword.get(kw, :audio_dir)
      _ -> nil
    end
  end

  # Best-effort file delete: a failure must not abort the run (Level E sweeps
  # the leftover on the next pass).
  defp delete_audio_file(filename, context) do
    dir = tts_audio_dir()

    if is_binary(dir) do
      case File.rm(Path.join(dir, filename)) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("Retention #{context}: could not delete #{filename}: #{inspect(reason)}")
      end
    end
  end

  # Filenames of rows that still own their audio (all live states).
  defp live_audio_paths do
    from(r in Request,
      where: r.state in [:requested, :processing, :ready],
      where: not is_nil(r.audio_path),
      select: r.audio_path
    )
    |> Repo.all()
  end

  # `<entry_id>.<ext>` files with their mtimes, whitelist-validated — the
  # same shape the worker writes and the podcast endpoint serves. Regular
  # files only; stat failures (race with the worker rewriting a file) skip
  # the entry instead of crashing the run.
  @audio_extensions ~w(mp3 m4a aac wav ogg flac)

  defp list_audio_files(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        for name <- names,
            filename_parts(name) == :ok,
            {:ok, %File.Stat{type: :regular, mtime: mtime}} <- [File.stat(Path.join(dir, name))] do
          {name, mtime_to_datetime(mtime)}
        end

      {:error, reason} ->
        Logger.warning("Retention orphan sweep: cannot list #{dir}: #{inspect(reason)}")
        []
    end
  end

  defp filename_parts(name) do
    case String.split(name, ".") do
      [id, ext] ->
        if Regex.match?(~r/^\d+$/, id) and ext in @audio_extensions, do: :ok, else: :skip

      _ ->
        :skip
    end
  end

  # File.stat mtime {{y, mo, d}, {h, mi, s}} is in the VM's local timezone —
  # convert through the calendar before comparing with UTC cutoffs.
  defp mtime_to_datetime(local) do
    local
    |> :calendar.local_time_to_universal_time_dst()
    |> hd()
    |> NaiveDateTime.from_erl!()
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.truncate(:second)
  end

  defp utc_now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
