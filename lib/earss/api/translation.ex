defmodule Earss.API.Translation do
  @moduledoc """
  Protocol-layer translation view (Goal 2, docs/translate.md).

  Attaches pre-fetched `entry_translations` to timeline rows so the renderers
  (GReader, Fever) can substitute translated title/summary/content without
  N+1 queries. Rules:

    * target language per row: `subscription.translate_to` (this user's
      override) → `feed.translate_to`
    * no target / no stored translation → original text, zero change
    * original layout (how the original text is attached after the
      translation), resolved per row: subscription `original_layout`
      (default `inline`) → feed `original_layout` (default `off`):
        * `off` — translation only
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

  Row maps need `:entry`, `:feed` (or nil), `:sub_translate_to` and
  `:original_layout` (subscription-level, optional).
  """
  @spec attach(map(), [map()], keyword()) :: [map()]
  def attach(_user, rows, opts \\ []) do
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
    Map.get(row, :sub_translate_to) || (row.feed && row.feed.translate_to)
  end

  defp decorate(row, translations) do
    lang = target_lang(row)
    translation = lang && translations[{row.entry.id, lang}]

    layout =
      cond do
        is_binary(Map.get(row, :sub_translate_to)) ->
          # per-subscription override: personal choice, default inline
          Map.get(row, :original_layout) || "inline"

        feed = row.feed ->
          # feed-level: opt-in via feed.original_layout (default off)
          feed.original_layout || "off"

        true ->
          "off"
      end

    row
    |> Map.put(:translation, translation)
    |> Map.put(:original_layout, layout)
  end

  # —— interleaved layout ——

  defp section_wrap(original) do
    ~s(<div class="earss-original-section">) <> original <> "</div>"
  end

  defp interleaved_content(%EntryTranslation{model: model_id} = translation, original_html) do
    translated_html = translation.content || ""

    case splitter_for(model_id) do
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
  # `model` records which plugin wrote the translation, so the right one is
  # asked even when several enrichers are registered.
  defp splitter_for(model_id) when is_binary(model_id) do
    case Enrichment.Registry.fetch(model_id) do
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
