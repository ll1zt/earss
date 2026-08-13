defmodule Earss.API.Translation do
  @moduledoc """
  Protocol-layer translation view (Goal 2, docs/translate.md).

  Attaches pre-fetched `entry_translations` to timeline rows so the renderers
  (GReader, Fever) can substitute translated title/summary/content without
  N+1 queries. Rules:

    * target language: `feed.translate_to` (feed-level config only —
      per-subscription overrides were removed in the single-user
      conversion, docs/single_user.md)
    * no target / no stored translation → original text, zero change
    * original layout (how the original text is attached after the
      translation) comes from `feed.original_layout`:
        * `off` — translation only (default)
        * `inline` — `译文<hr class="earss-original">原文`
        * `section` — same separator, original wrapped in a styled section
        * `interleaved` — paragraph-by-paragraph alternation (译文段 + 原文段),
          reliable because translated content is reassembled with the original
          block tags (block counts match)
    * `?original=1` (the `:original` opt) disables the whole view
  """

  alias Earss.Repo
  alias Earss.Feeds.EntryTranslation
  alias Earss.Enrichment

  import Ecto.Query

  @separator ~s(<hr class="earss-original">)

  @doc """
  Attach `:translation` (`EntryTranslation` or nil) and `:original_layout`
  (string) to each row.

  Row maps need `:entry` and `:feed` (or nil).
  """
  @spec attach([map()], keyword()) :: [map()]
  def attach(rows, opts \\ []) do
    if Keyword.get(opts, :original, false) do
      Enum.map(rows, &Map.put(&1, :translation, nil))
    else
      translations = fetch(rows)
      Enum.map(rows, &decorate(&1, translations))
    end
  end

  @doc "Rendered content for a row (translated, original, or combined per layout)."
  @spec content(map()) :: String.t()
  def content(row) do
    original = row.entry.content || row.entry.summary || ""
    translation = Map.get(row, :translation)
    layout = Map.get(row, :original_layout, "off")

    cond do
      is_nil(translation) ->
        original

      # Content already in the target language (e.g. a Chinese source with a
      # zh target, where the plugin stores an original-text copy): the
      # translation *is* the original — appending the original again would
      # render two identical copies of the text. Render it once.
      translation.content == original ->
        translation.content || original

      layout == "off" ->
        translation.content || original

      layout == "interleaved" ->
        interleaved_content(translation, original)

      layout == "section" ->
        (translation.content || "") <> @separator <> section_wrap(original)

      true ->
        (translation.content || "") <> @separator <> original
    end
  end

  @doc "Rendered title for a row (translated title when available)."
  @spec title(map()) :: String.t()
  def title(row) do
    case Map.get(row, :translation) do
      %{title: t} when is_binary(t) and t != "" -> t
      _ -> row.entry.title || ""
    end
  end

  # —— internals ——

  defp fetch(rows) do
    targets =
      rows
      |> Enum.map(fn row -> {row.entry.id, target_lang(row)} end)
      |> Enum.reject(fn {_id, lang} -> is_nil(lang) end)

    targets
    |> Enum.group_by(fn {_id, lang} -> lang end, fn {id, _lang} -> id end)
    |> Enum.reduce(%{}, fn {lang, ids}, acc ->
      from(t in EntryTranslation, where: t.lang == ^lang and t.entry_id in ^ids)
      |> Repo.all()
      |> Enum.reduce(acc, fn t, acc -> Map.put(acc, {t.entry_id, t.lang}, t) end)
    end)
  end

  defp target_lang(row) do
    row.feed && row.feed.translate_to
  end

  defp decorate(row, translations) do
    lang = target_lang(row)
    translation = lang && translations[{row.entry.id, lang}]

    row
    |> Map.put(:translation, translation)
    |> Map.put(:original_layout, (row.feed && row.feed.original_layout) || "off")
  end

  # —— interleaved layout ——

  defp section_wrap(original) do
    ~s(<div class="earss-original-section">) <> original <> "</div>"
  end

  defp interleaved_content(%EntryTranslation{} = translation, original_html) do
    translated_html = translation.content || ""

    case splitter_for(translation) do
      {:ok, mod} ->
        with {:ok, t} <- safe_split_blocks(mod, translated_html),
             {:ok, o} <- safe_split_blocks(mod, original_html) do
          zip_blocks(t, o)
        else
          _ -> section_fallback(translated_html, original_html)
        end

      :error ->
        section_fallback(translated_html, original_html)
    end
  end

  # The block structure comes from the plugin that produced the enrichment
  # (contract `split_blocks/1`): it knows its own output best. The stored
  # `enricher_id` records which plugin wrote the translation (the registry
  # key), so the right one is asked even when several enrichers are
  # registered. `model` is only a provider/LLM display string and is never a
  # registry key. Rows without an enricher_id (pre-migration) degrade to the
  # section layout.
  defp splitter_for(%EntryTranslation{enricher_id: id}) when is_binary(id) do
    case Enrichment.Registry.fetch(id) do
      {:ok, mod} ->
        if function_exported?(mod, :split_blocks, 1), do: {:ok, mod}, else: :error

      :error ->
        :error
    end
  end

  defp splitter_for(_), do: :error

  defp safe_split_blocks(mod, html) do
    mod.split_blocks(html)
  rescue
    _ -> {:error, :splitter_exception}
  end

  defp zip_blocks(translated_blocks, original_blocks) do
    max_len = max(length(translated_blocks), length(original_blocks))

    Enum.map_join(0..(max_len - 1), "", fn i ->
      translated = Enum.at(translated_blocks, i)
      original = Enum.at(original_blocks, i)

      (translated || "") <>
        if original do
          ~s(<div class="earss-original-block">) <> original <> "</div>"
        else
          ""
        end
    end)
  end

  defp section_fallback(translated_html, original_html) do
    (translated_html || "") <> @separator <> section_wrap(original_html)
  end
end
