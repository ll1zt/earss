defmodule Earss.Enrichment do
  @moduledoc """
  Host-side content enrichment orchestration (Goal 2, docs/translate.md).

  The host owns the **database-facing** half of enrichment: which entries are
  pending, when they become visible, retry/give-up policy, and storage of the
  enriched fields. The **domain algorithm** (how content is turned into its
  enriched form — HTML block handling for translation, audio synthesis for
  TTS, …) belongs to the plugin implementing `Earss.Source.Enricher`; entry
  content passed across the contract is opaque.

  Publish model: new entries of translated feeds are flagged
  `translation_pending_at` at ingest and hidden from protocol clients until
  every configured target language has a stored enrichment. Clients (e.g.
  NetNewsWire) only ever see the final form, so they never cache an
  untranslated original. Failed enrichments stay pending and are retried by
  `Earss.Enrichment.PendingWorker`; disabling a feed's translation clears its
  pending flags (original text becomes visible again).

  Responsibilities:

    * pick a registered `Earss.Source.Enricher` (first registered, sorted by
      id; tests inject one via the `:enricher` opt)
    * collect the languages a feed needs — its own `translate_to` plus every
      non-nil per-subscription `translate_to` — and enrich into all of them
    * pack each entry's fields opaquely, run the plugin's optional `skip?/2`,
      gate provider calls behind the global `Earss.Enrichment.Limiter`, and
      store results in `entry_translations` keyed by `(entry_id, lang)` —
      with strict ref/type validation before anything is written
    * `process_pending/1` retries entries whose enrichment failed

  Failures never block ingestion and never mutate the original entry: the
  feed's `translate_error_count` is bumped for observability instead.
  """

  alias Earss.Repo
  alias Earss.Feeds.{Entry, EntryTranslation, Feed}
  alias Earss.Enrichment.{Limiter, Registry}

  require Logger
  import Ecto.Query

  @default_budget %{max_entries: 20, max_chars: 100_000}
  @default_max_retries 5

  defp budget do
    :earss |> Application.get_env(:translate, []) |> Keyword.get(:budget, @default_budget)
  end

  @doc """
  Max consecutive enrichment failures before an entry gives up: its pending
  flag is cleared and the original text is published (the article is never
  hidden forever).
  """
  @spec max_pending_retries() :: pos_integer()
  def max_pending_retries do
    :earss
    |> Application.get_env(:translate, [])
    |> Keyword.get(:max_pending_retries, @default_max_retries)
  end

  # —— public API ——

  @doc "The default enricher module (first registered, sorted by id), or nil."
  @spec enricher() :: module() | nil
  def enricher do
    case Registry.list_enrichers() do
      [%{module: mod} | _] -> mod
      [] -> nil
    end
  end

  @doc """
  Languages a feed needs enrichments for. Single-operator mode: the
  feed-level `translate_to` is the only source (per-subscription overrides
  were removed, docs/single_user.md).
  """
  @spec languages_for_feed(Feed.t()) :: [String.t()]
  def languages_for_feed(%Feed{} = feed) do
    case feed.translate_to do
      nil -> []
      lang -> [lang]
    end
  end

  @doc """
  Mark freshly upserted entries as translation-pending (hidden from protocol
  clients until enrichments are ready). No-op when the feed has no
  translation target (neither feed-level nor any per-subscription override).

  Only entries **missing** at least one target language are flagged: entries
  whose stored translations are still fresh (`original_hash` matches the
  current `content_hash`) keep their visible state, so an ingest that merely
  re-upserts unchanged rows never hides already-published articles. The
  retry count and pause marker are never touched here — a paused entry stays
  paused until an admin decides (re-translate or publish the original).
  """
  @spec mark_pending(Feed.t(), [Entry.t()]) :: :ok
  def mark_pending(%Feed{} = feed, entries) do
    langs = languages_for_feed(feed)

    if langs != [] do
      ids = Enum.map(entries, & &1.id)

      ids
      |> missing_language_ids(langs, entries)
      |> flag_pending()
    end

    :ok
  end

  # Entry ids that lack a fresh translation for at least one target language.
  # "Fresh" means a stored `entry_translations` row whose `original_hash`
  # equals the entry's current `content_hash`.
  defp missing_language_ids(ids, langs, entries) do
    fresh =
      from(t in EntryTranslation,
        where: t.entry_id in ^ids and t.lang in ^langs,
        select: {t.entry_id, t.lang, t.original_hash},
        distinct: true
      )
      |> Repo.all()
      |> Enum.group_by(&elem(&1, 0), fn {_entry_id, lang, hash} -> {lang, hash} end)

    hash_by_id = Map.new(entries, &{&1.id, &1.content_hash})

    Enum.reject(ids, fn id ->
      entry_hash = Map.get(hash_by_id, id)

      Enum.all?(langs, fn lang ->
        Enum.any?(Map.get(fresh, id, []), fn {stored_lang, stored_hash} ->
          stored_lang == lang and stored_hash == entry_hash
        end)
      end)
    end)
  end

  defp flag_pending([]), do: :ok

  defp flag_pending(ids) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(e in Entry, where: e.id in ^ids)
    |> Repo.update_all(set: [translation_pending_at: now])

    :ok
  end

  @doc """
  Clear pending flags for a feed (translation disabled → original text
  visible again).
  """
  @spec clear_pending(Feed.t()) :: :ok
  def clear_pending(%Feed{id: feed_id}) do
    update_feed_entries(feed_id, :pending,
      translation_pending_at: nil,
      translation_paused_at: nil
    )
  end

  @doc """
  Re-translate a feed's paused entries: clears the pause marker and the
  retry counter so `Earss.Enrichment.PendingWorker` picks them up again.
  """
  @spec retry_paused(Feed.t()) :: :ok
  def retry_paused(%Feed{id: feed_id}) do
    update_feed_entries(feed_id, :paused,
      translation_paused_at: nil,
      translation_retry_count: 0
    )
  end

  @doc """
  Publish a feed's pending entries **without translating** (admin escape
  hatch): clears every pending flag (including paused ones) so the original
  text becomes visible to protocol clients.
  """
  @spec publish_pending(Feed.t()) :: :ok
  def publish_pending(%Feed{id: feed_id}) do
    update_feed_entries(feed_id, :pending,
      translation_pending_at: nil,
      translation_paused_at: nil,
      translation_retry_count: 0
    )
  end

  # The three bulk transitions above differ only in which rows they select
  # and which columns they clear, so they share one implementation.
  #
  # `:pending` selects every entry still hidden from protocol clients
  # (including paused ones, so an admin can publish an original for an entry
  # that gave up after max_pending_retries); `:paused` selects only the
  # subset awaiting that decision.
  defp update_feed_entries(feed_id, :pending, set) do
    from(e in Entry,
      where: e.feed_id == ^feed_id and not is_nil(e.translation_pending_at)
    )
    |> Repo.update_all(set: set)

    :ok
  end

  defp update_feed_entries(feed_id, :paused, set) do
    from(e in Entry,
      where: e.feed_id == ^feed_id and not is_nil(e.translation_paused_at)
    )
    |> Repo.update_all(set: set)

    :ok
  end

  @doc """
  Enrich one entry into its feed's languages (or the `:langs` opt).

  Returns `:no_enricher` or `{:ok, enriched_count}`. When every target
  language now has a stored enrichment, the entry's pending flag is cleared
  (it becomes visible); otherwise it stays pending for retry. Idempotent:
  existing enrichments whose `original_hash` matches are skipped, as are
  entries the plugin's optional `skip?/2` considers already written in the
  target language (those store an original-text copy so the entry still
  becomes visible).
  """
  @spec enrich_entry(Entry.t(), Feed.t(), keyword()) ::
          :no_enricher | {:ok, non_neg_integer()}
  def enrich_entry(entry, feed, opts \\ []) do
    case Keyword.get(opts, :enricher) || enricher() do
      nil ->
        :no_enricher

      mod ->
        langs = Keyword.get(opts, :langs) || languages_for_feed(feed)

        count =
          Enum.reduce(langs, 0, fn lang, acc ->
            case enrich_one(entry, feed, mod, lang) do
              :enriched ->
                acc + 1

              :skipped ->
                acc

              {:error, _reason} ->
                _ = bump_error(feed)
                _ = bump_retry_or_give_up(entry)
                acc
            end
          end)

        if all_languages_ready?(entry, langs) do
          _ = clear_entry_pending(entry)
        end

        {:ok, count}
    end
  end

  @doc """
  Enrich the newest entries of a feed, capped at the configured budget
  (used by the ingest hook; pass only newly upserted entries, already marked
  pending).

  The budget caps both the entry count (`max_entries`) and the cumulative
  input size in characters (`max_chars`, 0 = unlimited). At least one entry
  is always attempted; entries beyond the budget stay pending for the
  PendingWorker.
  """
  @spec enrich_new_entries(Feed.t(), [Entry.t()], keyword()) ::
          :no_enricher | {:ok, non_neg_integer()}
  def enrich_new_entries(feed, entries, opts \\ []) do
    start = System.monotonic_time()
    result = do_enrich_new_entries(feed, entries, opts)

    translated =
      case result do
        {:ok, n} -> n
        _ -> 0
      end

    :telemetry.execute(
      Earss.Telemetry.event_enrichment_translate(),
      %{
        duration: System.monotonic_time() - start,
        entries: length(entries),
        translated: translated
      },
      %{feed_id: feed.id}
    )

    result
  end

  defp do_enrich_new_entries(feed, entries, opts) do
    cfg = Keyword.get(opts, :budget, budget())
    max_entries = max(cfg.max_entries, 0)
    max_chars = cfg.max_chars || 0

    entries
    |> Enum.take(max_entries)
    |> Enum.reduce_while({:ok, 0, 0}, fn entry, {:ok, acc, chars} ->
      size = entry_size(entry)

      if chars > 0 and max_chars > 0 and chars + size > max_chars do
        {:halt, {:ok, acc, chars}}
      else
        case enrich_entry(entry, feed, opts) do
          :no_enricher -> {:cont, {:ok, acc, chars}}
          {:ok, n} -> {:cont, {:ok, acc + n, chars + size}}
        end
      end
    end)
    |> then(fn {:ok, count, _chars} -> {:ok, count} end)
  end

  defp entry_size(entry) do
    [entry.title, entry.summary, entry.content]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&String.length/1)
    |> Enum.sum()
  end

  @doc """
  Retry pending entries (used by `Earss.Enrichment.PendingWorker`).

  Enriches up to `limit` entries still flagged pending and not paused. Each
  failure bumps the entry's `translation_retry_count`; after
  `max_pending_retries` consecutive failures the entry is **paused**
  (`translation_paused_at` set, pending flag kept — it stays hidden from
  protocol clients) and left for an admin decision: re-translate
  (`retry_paused/1`) or publish the original (`publish_pending/1`).

  **Orphans are always cleared**, paused or not: a feed without a
  translation target (config removed, last subscription override dropped) or
  with no registered enricher (plugin removed at runtime) can never produce
  enrichments — keeping the entries hidden would leak them from every
  reader's timeline forever. Returns the number of entries whose
  enrichments were stored.
  """
  @spec process_pending(pos_integer(), keyword()) :: non_neg_integer()
  def process_pending(limit \\ 100, opts \\ []) do
    start = System.monotonic_time()
    processed = do_process_pending(limit, opts)

    :telemetry.execute(
      Earss.Telemetry.event_enrichment_pending(),
      %{duration: System.monotonic_time() - start, processed: processed},
      %{}
    )

    processed
  end

  defp do_process_pending(limit, opts) do
    enricher = Keyword.get(opts, :enricher) || enricher()

    rows =
      from(e in Entry,
        join: f in Feed,
        on: f.id == e.feed_id,
        where: not is_nil(e.translation_pending_at),
        # paused entries first would starve the retry batch; process active
        # pending entries first, then paused ones (orphan cleanup)
        order_by: [asc_nulls_first: e.translation_paused_at, asc: e.id],
        limit: ^limit,
        select: {e, f}
      )
      |> Repo.all()

    Enum.reduce(rows, 0, fn {entry, feed}, acc ->
      cond do
        # No enricher or no target language: publishing the original is the
        # only sensible outcome — including for paused entries, which would
        # otherwise stay hidden forever (they are excluded from the normal
        # retry path and no admin action may ever arrive).
        is_nil(enricher) or languages_for_feed(feed) == [] ->
          _ = clear_entry_pending(entry)
          acc

        # Paused: awaiting an admin decision (re-translate or publish).
        not is_nil(entry.translation_paused_at) ->
          acc

        true ->
          case enrich_entry(entry, feed, opts) do
            {:ok, n} -> acc + n
            _ -> acc
          end
      end
    end)
  end

  @doc """
  Enrichment statistics for a feed (admin pages).

  Returns `total` entries (all fetched, including pre-enable stock), `need`
  entries that actually require enrichment (enrichment enabled since the
  entry was fetched — translated, pending, or paused), `pending` entries
  still being processed (hidden, not paused), `paused` entries whose
  translation failed too often (hidden, awaiting an admin decision),
  per-language enriched counts and the feed's `translate_error_count`.

  `need` is the correct denominator for "already done / to do": pre-enable
  entries that never get enriched are *not* counted.
  """
  @spec stats(Feed.t()) :: map()
  def stats(%Feed{} = feed) do
    total =
      from(e in Entry, where: e.feed_id == ^feed.id)
      |> Repo.aggregate(:count)

    langs = languages_for_feed(feed)

    # Entries that had a pending flag (enrichment enabled since they were
    # fetched): successfully enriched entries (pending cleared) + entries
    # still pending (processing or paused). Mutually exclusive — a
    # partially-enriched multi-language entry keeps its pending flag until
    # every target language is stored.
    enriched_entries =
      from(t in EntryTranslation,
        join: e in Entry,
        on: e.id == t.entry_id,
        where: e.feed_id == ^feed.id and is_nil(e.translation_pending_at),
        distinct: t.entry_id
      )
      |> Repo.aggregate(:count)

    pending =
      from(e in Entry,
        where:
          e.feed_id == ^feed.id and not is_nil(e.translation_pending_at) and
            is_nil(e.translation_paused_at)
      )
      |> Repo.aggregate(:count)

    paused =
      from(e in Entry,
        where: e.feed_id == ^feed.id and not is_nil(e.translation_paused_at)
      )
      |> Repo.aggregate(:count)

    translated =
      if langs == [] do
        %{}
      else
        from(t in EntryTranslation,
          join: e in Entry,
          on: e.id == t.entry_id,
          where: e.feed_id == ^feed.id and t.lang in ^langs,
          group_by: t.lang,
          select: {t.lang, count(t.id)}
        )
        |> Repo.all()
        |> Map.new()
      end

    %{
      total: total,
      need: enriched_entries + pending + paused,
      pending: pending,
      paused: paused,
      languages: translated,
      errors: feed.translate_error_count || 0
    }
  end

  @doc """
  Batch variant of `stats/1` for many feeds (admin pages): same per-feed
  shape, computed with a constant number of queries instead of ~6 per feed.
  Returns `%{feed_id => stats_map}`.
  """
  @spec stats_many([Feed.t()]) :: %{optional(pos_integer()) => map()}
  def stats_many(feeds) when is_list(feeds) do
    ids = Enum.map(feeds, & &1.id)
    by_id = Map.new(feeds, &{&1.id, &1})

    # single-operator mode: the feed-level translate_to is the only source
    langs =
      Map.new(ids, fn id ->
        case by_id[id].translate_to do
          nil -> {id, []}
          lang -> {id, [lang]}
        end
      end)

    totals =
      from(e in Entry,
        where: e.feed_id in ^ids,
        group_by: e.feed_id,
        select: {e.feed_id, count(e.id)}
      )
      |> Repo.all()
      |> Map.new()

    enriched =
      from(t in EntryTranslation,
        join: e in Entry,
        on: e.id == t.entry_id,
        where: e.feed_id in ^ids and is_nil(e.translation_pending_at),
        group_by: e.feed_id,
        select: {e.feed_id, count(t.entry_id, :distinct)}
      )
      |> Repo.all()
      |> Map.new()

    pending =
      from(e in Entry,
        where:
          e.feed_id in ^ids and not is_nil(e.translation_pending_at) and
            is_nil(e.translation_paused_at),
        group_by: e.feed_id,
        select: {e.feed_id, count(e.id)}
      )
      |> Repo.all()
      |> Map.new()

    paused =
      from(e in Entry,
        where: e.feed_id in ^ids and not is_nil(e.translation_paused_at),
        group_by: e.feed_id,
        select: {e.feed_id, count(e.id)}
      )
      |> Repo.all()
      |> Map.new()

    translated =
      from(t in EntryTranslation,
        join: e in Entry,
        on: e.id == t.entry_id,
        where: e.feed_id in ^ids,
        group_by: [e.feed_id, t.lang],
        select: {e.feed_id, t.lang, count(t.id)}
      )
      |> Repo.all()
      |> Enum.reduce(%{}, fn {fid, lang, count}, acc ->
        if lang in Map.get(langs, fid, []) do
          Map.update(acc, fid, %{lang => count}, &Map.put(&1, lang, count))
        else
          acc
        end
      end)

    Map.new(ids, fn id ->
      {id,
       %{
         total: Map.get(totals, id, 0),
         need: Map.get(enriched, id, 0) + Map.get(pending, id, 0) + Map.get(paused, id, 0),
         pending: Map.get(pending, id, 0),
         paused: Map.get(paused, id, 0),
         languages: Map.get(translated, id, %{}),
         errors: by_id[id].translate_error_count || 0
       }}
    end)
  end

  # —— per-entry, per-language enrichment ——

  defp enrich_one(entry, feed, mod, lang) do
    if fresh_translation?(entry, lang) do
      :skipped
    else
      do_enrich(entry, feed, mod, lang)
    end
  end

  # A stored translation is usable only while it was produced from the text
  # the entry still holds: `original_hash` is the entry's `content_hash` at
  # the time of the enrichment.
  defp fresh_translation?(entry, lang) do
    fresh?(entry.id, lang, entry.content_hash)
  end

  defp fresh?(entry_id, lang, content_hash) do
    case Repo.get_by(EntryTranslation, entry_id: entry_id, lang: lang) do
      %{original_hash: hash} -> hash == content_hash
      nil -> false
    end
  end

  defp plugin_skips?(mod, payload, opts) do
    if function_exported?(mod, :skip?, 2) do
      try do
        mod.skip?(payload, opts) == true
      rescue
        _ -> false
      end
    else
      false
    end
  end

  defp do_enrich(entry, feed, mod, lang) do
    payload = %{ref: entry.id, title: entry.title, summary: entry.summary, content: entry.content}
    opts = [target_lang: lang, source_lang: feed.translate_from]

    if plugin_skips?(mod, payload, opts) do
      # Already in the target language: store an original-text copy so the
      # entry becomes visible without spending a provider call.
      persist(
        entry,
        lang,
        %{title: entry.title, summary: entry.summary, content: entry.content},
        mod,
        %{skipped: true}
      )
    else
      with {:ok, results} <- safe_enrich(mod, [payload], opts),
           :ok <- validate_refs([payload], results),
           {:ok, fields, meta} <- extract_result(results) do
        persist(entry, lang, fields, mod, meta)
      else
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # Plugin crashes (HTTP layer, bugs) become ordinary errors so one bad entry
  # can never take down a run. Provider calls are gated by the global Limiter
  # (max_concurrency, default 1).
  defp safe_enrich(mod, payloads, opts) do
    Limiter.acquire()

    try do
      mod.enrich(payloads, opts)
    rescue
      e -> {:error, {:enricher_exception, Exception.message(e)}}
    catch
      kind, reason -> {:error, {:enricher_throw, kind, reason}}
    after
      Limiter.release()
    end
  end

  # Contract rule: the result ref set must match the input ref set exactly
  # (no missing, duplicated or foreign refs) — otherwise nothing is stored.
  defp validate_refs(payloads, results) do
    expected = payloads |> Enum.map(& &1.ref) |> MapSet.new()
    found = results |> Enum.map(& &1.ref) |> MapSet.new()

    if expected == found and length(results) == MapSet.size(found) do
      :ok
    else
      {:error, :ref_mismatch}
    end
  end

  # Contract rule: title/summary/content must be strings or nil.
  defp extract_result([%{ref: _ref, title: t, summary: s, content: c} = result]) do
    if Enum.all?([t, s, c], fn v -> is_nil(v) or is_binary(v) end) do
      {:ok, %{title: t, summary: s, content: c}, Map.get(result, :meta, %{})}
    else
      {:error, :invalid_fields}
    end
  end

  defp extract_result(_), do: {:error, :invalid_result}

  # —— persistence ——

  defp persist(entry, lang, fields, mod, meta) do
    attrs = %{
      entry_id: entry.id,
      lang: lang,
      title: fields.title,
      summary: fields.summary,
      content: fields.content,
      original_hash: entry.content_hash,
      model: Map.get(meta, :model) || mod.id(),
      # The plugin id is the registry key the protocol layer uses to ask the
      # producing plugin for block structure (interleaved layout); `model`
      # keeps the provider/LLM string for display.
      enricher_id: mod.id(),
      translated_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    changeset = EntryTranslation.changeset(%EntryTranslation{}, attrs)

    case Repo.insert(changeset,
           on_conflict:
             {:replace,
              [
                :title,
                :summary,
                :content,
                :original_hash,
                :model,
                :enricher_id,
                :translated_at
              ]},
           conflict_target: [:entry_id, :lang]
         ) do
      {:ok, _} ->
        # Touch the entry so protocol responses report a newer `updated` for
        # clients that honour it.
        _ = touch_entry(entry)
        :enriched

      {:error, changeset} ->
        {:error, {:persist, changeset}}
    end
  end

  # Bumps `updated_at` so protocol responses report a newer `updated` for
  # clients that honour it. Not rescued: the caller runs inside
  # `enrich_entry/3`, whose failure path is already the right answer (the
  # entry stays pending and `PendingWorker` retries it).
  defp touch_entry(entry) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    entry
    |> Ecto.Changeset.change(%{updated_at: now})
    |> Repo.update()

    :ok
  end

  # Counter for the admin pages. Not rescued: an unreachable DB fails the
  # whole enrichment run either way, and swallowing it here would hide the
  # outage from the one place that reports it.
  defp bump_error(feed) do
    Feed.changeset(feed, %{translate_error_count: (feed.translate_error_count || 0) + 1})
    |> Repo.update()

    :ok
  end

  # —— pending helpers ——

  # Publishable once every target language has a translation derived from the
  # entry's current content. An entry translated into only some of its
  # languages stays pending.
  defp all_languages_ready?(entry, langs) do
    langs != [] and Enum.all?(langs, &fresh?(entry.id, &1, entry.content_hash))
  end

  # Publishes the entry (original text becomes visible). Not rescued: if
  # this cannot be written the entry stays hidden, and the operator needs to
  # see that rather than have it swallowed.
  defp clear_entry_pending(entry) do
    from(e in Entry, where: e.id == ^entry.id)
    |> Repo.update_all(
      set: [translation_pending_at: nil, translation_retry_count: 0, translation_paused_at: nil]
    )

    :ok
  end

  # Failed attempt: increment the retry counter; once the limit is reached,
  # pause the entry (translation_paused_at set, pending flag kept) so it stays
  # hidden and an admin decides: re-translate or publish the original.
  defp bump_retry_or_give_up(entry) do
    retries = entry.translation_retry_count || 0
    max = max_pending_retries()

    if retries + 1 >= max do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Logger.warning(
        "translation paused for entry #{entry.id} after #{max} failed attempts; " <>
          "waiting for admin (re-translate or publish original)"
      )

      from(e in Entry, where: e.id == ^entry.id)
      |> Repo.update_all(set: [translation_retry_count: max, translation_paused_at: now])
    else
      from(e in Entry, where: e.id == ^entry.id)
      |> Repo.update_all(inc: [translation_retry_count: 1])
    end

    :ok
  end
end
