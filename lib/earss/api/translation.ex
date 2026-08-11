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
  alias Earss.Translate.HTML

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
        interleaved_content(translation.content, original)

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

  defp interleaved_content(nil, _original), do: ""

  defp interleaved_content(translated_html, original_html) do
    translated_blocks = blocks_of(translated_html)
    original_blocks = blocks_of(original_html)

    max_len = max(length(translated_blocks), length(original_blocks))

    Enum.map_join(0..(max_len - 1), "", fn i ->
      translated = Enum.at(translated_blocks, i)
      original = Enum.at(original_blocks, i)

      translated_html = if translated, do: render_block(translated), else: ""

      original_html =
        if original do
          ~s(<div class="earss-original-block">) <> render_block(original) <> "</div>"
        else
          ""
        end

      translated_html <> original_html
    end)
  end

  defp blocks_of(html) when is_binary(html) do
    case HTML.extract_blocks(html) do
      {:ok, blocks} -> blocks
      {:error, _} -> []
    end
  end

  defp blocks_of(_), do: []

  defp render_block(%{type: :raw, text: raw}), do: raw

  defp render_block(block) do
    case HTML.render_block(block.text, block) do
      {:ok, html} -> html
      {:error, _} -> block.text
    end
  end
end
