defmodule Earss.Translate do
  @moduledoc """
  Host-side translation orchestration (Goal 2, docs/translate.md).

  Publish model: new entries of translated feeds are flagged
  `translation_pending_at` at ingest and hidden from protocol clients until
  every configured target language has a stored translation. Clients (e.g.
  NetNewsWire) only ever see the final form, so they never cache an
  untranslated original. Failed translations stay pending and are retried by
  `Earss.Translate.PendingWorker`; disabling a feed's translation clears its
  pending flags (original text becomes visible again).

  Responsibilities:

    * pick a registered `Earss.Source.Translator` (first registered, sorted
      by id; tests inject one via the `:translator` opt)
    * collect the languages a feed needs — its own `translate_to` plus every
      non-nil per-subscription `translate_to` — and translate into all of them
    * build one batched provider call per entry (title + summary + content
      blocks), reassemble HTML blocks, and store copies in
      `entry_translations` keyed by `(entry_id, lang)`
    * `process_pending/1` retries entries whose translation failed

  Failures never block ingestion and never mutate the original entry: the
  feed's `translate_error_count` is bumped for observability instead.
  """

  alias Earss.Repo
  alias Earss.Feeds.{Entry, EntryTranslation, Feed}
  alias Earss.Reader.Subscription
  alias Earss.Translate.{HTML, Lang, Limiter, Registry}

  require Logger
  import Ecto.Query

  @default_budget %{max_entries: 20, max_chars: 100_000}

  defp budget do
    :earss |> Application.get_env(:translate, []) |> Keyword.get(:budget, @default_budget)
  end

  # —— public API ——

  @doc "The default translator module (first registered, sorted by id), or nil."
  @spec translator() :: module() | nil
  def translator do
    case Registry.list_translators() do
      [%{module: mod} | _] -> mod
      [] -> nil
    end
  end

  @doc """
  Languages a feed needs translations for: `feed.translate_to` ∪ all non-null
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
  clients until translations are ready). No-op when the feed has no
  translation target (neither feed-level nor any per-subscription override).
  """
  @spec mark_pending(Feed.t(), [Entry.t()]) :: :ok
  def mark_pending(%Feed{} = feed, entries) do
    if languages_for_feed(feed) != [] do
      ids = Enum.map(entries, & &1.id)

      if ids != [] do
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        from(e in Entry, where: e.id in ^ids)
        |> Repo.update_all(set: [translation_pending_at: now])
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
  Translate one entry into its feed's languages (or the `:langs` opt).

  Returns `:no_translator` or `{:ok, translated_count}`. When every target
  language now has a stored translation, the entry's pending flag is cleared
  (it becomes visible); otherwise it stays pending for retry. Idempotent:
  existing translations whose `original_hash` matches are skipped, as are
  entries the local heuristic (or plugin `skip?/2`) considers already written
  in the target language.
  """
  @spec translate_entry(Entry.t(), Feed.t(), keyword()) ::
          :no_translator | {:ok, non_neg_integer()}
  def translate_entry(entry, feed, opts \\ []) do
    case Keyword.get(opts, :translator) || translator() do
      nil ->
        :no_translator

      mod ->
        langs = Keyword.get(opts, :langs) || languages_for_feed(feed)

        count =
          Enum.reduce(langs, 0, fn lang, acc ->
            case translate_one(entry, feed, mod, lang) do
              :translated ->
                acc + 1

              :skipped ->
                acc

              {:error, _reason} ->
                _ = bump_error(feed)
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
  Translate the newest entries of a feed, capped at the configured budget
  (used by the ingest hook; pass only newly upserted entries, already marked
  pending).
  """
  @spec translate_new_entries(Feed.t(), [Entry.t()], keyword()) ::
          :no_translator | {:ok, non_neg_integer()}
  def translate_new_entries(feed, entries, opts \\ []) do
    cfg = Keyword.get(opts, :budget, budget())

    entries
    |> Enum.take(max(cfg.max_entries, 0))
    |> Enum.reduce({:ok, 0}, fn entry, {:ok, acc} ->
      case translate_entry(entry, feed, opts) do
        :no_translator -> {:ok, acc}
        {:ok, n} -> {:ok, acc + n}
      end
    end)
  end

  @doc """
  Retry pending entries (used by `Earss.Translate.PendingWorker`).

  Translates up to `limit` entries still flagged pending. A feed without a
  translation target clears its pending flags (orphans from a disabled feed).
  Returns the number of entries whose translations were stored.
  """
  @spec process_pending(pos_integer()) :: non_neg_integer()
  def process_pending(limit \\ 100) do
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
        case translate_entry(entry, feed) do
          {:ok, n} -> acc + n
          _ -> acc
        end
      end
    end)
  end

  @doc """
  Translation statistics for a feed (admin pages).

  Returns `total` entries, per-language translated counts and the feed's
  `translate_error_count`.
  """
  @spec stats(Feed.t()) :: map()
  def stats(%Feed{} = feed) do
    total =
      from(e in Entry, where: e.feed_id == ^feed.id)
      |> Repo.aggregate(:count)

    langs = languages_for_feed(feed)

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
      languages: translated,
      errors: feed.translate_error_count || 0
    }
  end

  # —— per-entry, per-language translation ——

  defp translate_one(entry, feed, mod, lang) do
    cond do
      fresh_translation?(entry, lang) -> :skipped
      Lang.skip?(sample_text(entry), lang) -> :skipped
      plugin_skips?(mod, entry, lang) -> :skipped
      true -> do_translate(entry, feed, mod, lang)
    end
  end

  defp fresh_translation?(entry, lang) do
    case Repo.get_by(EntryTranslation, entry_id: entry.id, lang: lang) do
      %{original_hash: hash} -> hash == entry.content_hash
      nil -> false
    end
  end

  defp plugin_skips?(mod, entry, lang) do
    if function_exported?(mod, :skip?, 2) do
      try do
        mod.skip?(sample_text(entry), lang) == true
      rescue
        _ -> false
      end
    else
      false
    end
  end

  defp sample_text(entry) do
    [entry.title, entry.summary, entry.content]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
    |> String.slice(0, 500)
  end

  defp do_translate(entry, feed, mod, lang) do
    if String.length(sample_text(entry)) > budget().max_chars do
      {:error, :over_budget}
    else
      with {:ok, plan} <- build_plan(entry),
           {:ok, translations} <- safe_translate(mod, plan_items(plan), feed, lang),
           {:ok, fields} <- assemble(plan, translations) do
        persist(entry, lang, fields, mod)
      else
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # Plugin crashes (HTTP layer, bugs) become ordinary errors so one bad entry
  # can never take down a run. Provider calls are gated by the global Limiter
  # (max_concurrency, default 1).
  defp safe_translate(mod, items, feed, lang) do
    Limiter.acquire()

    try do
      mod.translate(items, target_lang: lang, source_lang: feed.translate_from)
    rescue
      e -> {:error, {:translator_exception, Exception.message(e)}}
    catch
      kind, reason -> {:error, {:translator_throw, kind, reason}}
    after
      Limiter.release()
    end
  end

  # —— plan: split entry into translatable units ——

  defp build_plan(entry) do
    {:ok,
     %{
       title: text_plan("t", entry.title),
       summary: html_plan("s", entry.summary),
       content: html_plan("b", entry.content)
     }}
  end

  defp text_plan(key, nil), do: %{kind: :text, key: key, text: ""}
  defp text_plan(key, text), do: %{kind: :text, key: key, text: String.trim(text)}

  defp html_plan(key, nil), do: %{kind: :blocks, key: key, blocks: []}

  defp html_plan(key, html) do
    blocks =
      case HTML.extract_blocks(html) do
        {:ok, blocks} ->
          blocks

        {:error, _} ->
          [%{type: :text, text: HTML.to_plain_text(html), placeholders: %{}}]
      end

    blocks =
      blocks
      |> Enum.with_index()
      |> Enum.map(fn {block, i} -> Map.put(block, :key, "#{key}#{i}") end)

    %{kind: :blocks, key: key, blocks: blocks}
  end

  defp plan_items(plan) do
    plan
    |> collect_items([])
    |> Enum.reverse()
  end

  defp collect_items(plan, acc) do
    Enum.reduce(Map.values(plan), acc, fn
      %{kind: :text, key: key, text: text}, acc when is_binary(text) and text != "" ->
        [%{key: key, text: text} | acc]

      %{kind: :blocks, blocks: blocks}, acc ->
        Enum.reduce(blocks, acc, fn block, acc ->
          if block.type == :raw or block.text == "" do
            acc
          else
            [%{key: block.key, text: block.text} | acc]
          end
        end)

      _, acc ->
        acc
    end)
  end

  # —— assemble translations back into fields ——

  defp assemble(plan, translations) do
    by_key = Map.new(translations, &{&1.key, &1.translated})

    with {:ok, title} <- assemble_text(plan.title, by_key),
         {:ok, summary} <- assemble_field(plan.summary, by_key),
         {:ok, content} <- assemble_field(plan.content, by_key) do
      {:ok, %{title: title, summary: summary, content: content}}
    end
  end

  defp assemble_text(%{kind: :text, key: key, text: original}, by_key) do
    {:ok, Map.get(by_key, key) || if(original == "", do: nil, else: original)}
  end

  defp assemble_field(%{kind: :blocks, blocks: blocks}, by_key) do
    parts =
      Enum.map(blocks, fn block ->
        case Map.get(by_key, block.key) do
          nil ->
            original_html(block)

          translated ->
            case HTML.render_block(translated, block) do
              {:ok, html} -> html
              {:error, _} -> original_html(block)
            end
        end
      end)

    {:ok, Enum.join(parts)}
  end

  defp original_html(%{type: :raw, text: raw}), do: raw

  defp original_html(block) do
    case HTML.render_block(block.text, block) do
      {:ok, html} -> html
      {:error, _} -> block.text
    end
  end

  # —— persistence ——

  defp persist(entry, lang, fields, mod) do
    attrs = %{
      entry_id: entry.id,
      lang: lang,
      title: fields.title,
      summary: fields.summary,
      content: fields.content,
      original_hash: entry.content_hash,
      model: mod.id(),
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
        :translated

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
    |> Repo.update_all(set: [translation_pending_at: nil])

    :ok
  rescue
    _ -> :ok
  end
end
