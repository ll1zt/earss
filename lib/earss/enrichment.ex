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
  alias Earss.Reader.Subscription
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
  Languages a feed needs enrichments for: `feed.translate_to` ∪ all non-null
  subscription `translate_to` values.
  """
  @spec languages_for_feed(Feed.t()) :: [String.t()]
  def languages_for_feed(%Feed{} = feed) do
    sub_langs =
      from(s in Subscription,
        where: s.feed_id == ^feed.id and not is_nil(s.translate_to),
        select: s.translate_to
      )
      |> Repo.all()

    [feed.translate_to | sub_langs]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  @doc """
  Mark freshly upserted entries as translation-pending (hidden from protocol
  clients until enrichments are ready). No-op when the feed has no
  translation target (neither feed-level nor any per-subscription override).
  """
  @spec mark_pending(Feed.t(), [Entry.t()]) :: :ok
  def mark_pending(%Feed{} = feed, entries) do
    if languages_for_feed(feed) != [] do
      ids = Enum.map(entries, & &1.id)

      if ids != [] do
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        from(e in Entry, where: e.id in ^ids)
        |> Repo.update_all(set: [translation_pending_at: now, translation_retry_count: 0])
      end
    end

    :ok
  end

  @doc """
  Clear pending flags for a feed (translation disabled → original text
  visible again).
  """
  @spec clear_pending(Feed.t()) :: :ok
  def clear_pending(%Feed{id: feed_id}) do
    from(e in Entry,
      where: e.feed_id == ^feed_id and not is_nil(e.translation_pending_at)
    )
    |> Repo.update_all(set: [translation_pending_at: nil])

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
  """
  @spec enrich_new_entries(Feed.t(), [Entry.t()], keyword()) ::
          :no_enricher | {:ok, non_neg_integer()}
  def enrich_new_entries(feed, entries, opts \\ []) do
    cfg = Keyword.get(opts, :budget, budget())

    entries
    |> Enum.take(max(cfg.max_entries, 0))
    |> Enum.reduce({:ok, 0}, fn entry, {:ok, acc} ->
      case enrich_entry(entry, feed, opts) do
        :no_enricher -> {:ok, acc}
        {:ok, n} -> {:ok, acc + n}
      end
    end)
  end

  @doc """
  Retry pending entries (used by `Earss.Enrichment.PendingWorker`).

  Enriches up to `limit` entries still flagged pending. Each failure bumps
  the entry's `translation_retry_count`; after `max_pending_retries`
  consecutive failures the entry **gives up**: its pending flag is cleared and
  the original text is published (the article is never hidden forever). A
  feed without a translation target clears its pending flags too (orphans
  from a disabled feed). Returns the number of entries whose enrichments
  were stored.
  """
  @spec process_pending(pos_integer(), keyword()) :: non_neg_integer()
  def process_pending(limit \\ 100, opts \\ []) do
    rows =
      from(e in Entry,
        join: f in Feed,
        on: f.id == e.feed_id,
        where: not is_nil(e.translation_pending_at),
        order_by: [asc: e.id],
        limit: ^limit,
        select: {e, f}
      )
      |> Repo.all()

    Enum.reduce(rows, 0, fn {entry, feed}, acc ->
      if languages_for_feed(feed) == [] do
        _ = clear_entry_pending(entry)
        acc
      else
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
  entry was fetched — translated, pending, or given-up entries that had a
  pending flag), `pending` entries still awaiting a successful enrichment,
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
    # still pending. Mutually exclusive — a partially-enriched multi-language
    # entry keeps its pending flag until every target language is stored.
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
        where: e.feed_id == ^feed.id and not is_nil(e.translation_pending_at)
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
      need: enriched_entries + pending,
      pending: pending,
      languages: translated,
      errors: feed.translate_error_count || 0
    }
  end

  # —— per-entry, per-language enrichment ——

  defp enrich_one(entry, feed, mod, lang) do
    if fresh_translation?(entry, lang) do
      :skipped
    else
      do_enrich(entry, feed, mod, lang)
    end
  end

  defp fresh_translation?(entry, lang) do
    case Repo.get_by(EntryTranslation, entry_id: entry.id, lang: lang) do
      %{original_hash: hash} -> hash == entry.content_hash
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
      translated_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    changeset = EntryTranslation.changeset(%EntryTranslation{}, attrs)

    case Repo.insert(changeset,
           on_conflict:
             {:replace, [:title, :summary, :content, :original_hash, :model, :translated_at]},
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

  defp touch_entry(entry) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    entry
    |> Ecto.Changeset.change(%{updated_at: now})
    |> Repo.update()

    :ok
  rescue
    _ -> :ok
  end

  # Best-effort: a DB hiccup here must never crash the caller.
  defp bump_error(feed) do
    Feed.changeset(feed, %{translate_error_count: (feed.translate_error_count || 0) + 1})
    |> Repo.update()

    :ok
  rescue
    _ -> :ok
  end

  # —— pending helpers ——

  defp all_languages_ready?(entry, langs) do
    langs != [] and
      Enum.all?(langs, fn lang ->
        case Repo.get_by(EntryTranslation, entry_id: entry.id, lang: lang) do
          %{original_hash: hash} -> hash == entry.content_hash
          nil -> false
        end
      end)
  end

  defp clear_entry_pending(entry) do
    from(e in Entry, where: e.id == ^entry.id)
    |> Repo.update_all(set: [translation_pending_at: nil, translation_retry_count: 0])

    :ok
  rescue
    _ -> :ok
  end

  # Failed attempt: increment the retry counter; once the limit is reached,
  # give up and publish the original so the article is never hidden forever.
  defp bump_retry_or_give_up(entry) do
    retries = entry.translation_retry_count || 0
    max = max_pending_retries()

    if retries + 1 >= max do
      Logger.warning(
        "translation gave up for entry #{entry.id} after #{max} failed attempts; publishing original"
      )

      _ = clear_entry_pending(entry)
    else
      from(e in Entry, where: e.id == ^entry.id)
      |> Repo.update_all(inc: [translation_retry_count: 1])
    end

    :ok
  rescue
    _ -> :ok
  end
end
