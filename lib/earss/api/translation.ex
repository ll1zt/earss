defmodule Earss.API.Translation do
  @moduledoc """
  Protocol-layer translation view (Goal 2, docs/translate.md).

  Attaches pre-fetched `entry_translations` to timeline rows so the renderers
  (GReader, Fever) can substitute translated title/summary/content without
  N+1 queries. Rules:

    * target language per row: `subscription.translate_to` (this user's
      override) → `feed.translate_to`
    * no target / no stored translation → original text, zero change
    * append original: per-subscription overrides when `return_original` is
      not false (default on), or feed-level when `feed.return_original` is
      enabled — output `译文<hr class="earss-original">原文`
    * `?original=1` (the `:original` opt) disables the whole view
  """

  alias Earss.Repo
  alias Earss.Feeds.EntryTranslation

  import Ecto.Query

  @separator ~s(<hr class="earss-original">)

  @doc """
  Attach `:translation` (`EntryTranslation` or nil) and `:append_original`
  (boolean) to each row.

  Row maps need `:entry`, `:feed` (or nil), `:sub_translate_to` and
  `:return_original`.
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

  @doc "Rendered content for a row (translated, original, or concatenated)."
  @spec content(map()) :: String.t()
  def content(row) do
    original = row.entry.content || row.entry.summary || ""
    translation = Map.get(row, :translation)

    cond do
      is_nil(translation) ->
        original

      Map.get(row, :append_original, false) ->
        (translation.content || "") <> @separator <> original

      true ->
        translation.content || original
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

    append =
      cond do
        is_binary(Map.get(row, :sub_translate_to)) ->
          # per-subscription override: personal choice, default on
          Map.get(row, :return_original, true) != false

        feed = row.feed ->
          # feed-level translation: opt-in via feed.return_original
          feed.return_original == true

        true ->
          false
      end

    row
    |> Map.put(:translation, translation)
    |> Map.put(:append_original, append)
  end
end
