defmodule Earss.TTS.Lang do
  @moduledoc """
  Conservative language-detection heuristics for choosing a TTS voice.

  Same script-ratio approach as the translation plugin's local skip
  heuristic, kept here so the TTS contract package never depends on
  `earss_translate_openai`. Detects the script family of a text sample so
  the host can pick a matching `voice_key` per language.

  ## Detection

    * `script/1` — `:zh` | `:ja` | `:ko` | `:latin` | `:other`
    * CJK ratio thresholds mirror the translation heuristics: Chinese text
      is CJK-heavy and kana-free; Japanese is kana-heavy; Korean is
      hangul-heavy; everything else falls back to `:latin` when it has any
      Latin letters.

  Only skips/decides when the script evidence is strong; ambiguous text
  defaults to `:latin` (or the host's configured default voice).
  """

  @cjk_ranges [{0x3400, 0x4DBF}, {0x4E00, 0x9FFF}]
  @kana_ranges [{0x3040, 0x309F}, {0x30A0, 0x30FF}]
  @hangul_ranges [{0xAC00, 0xD7AF}]
  @latin_ranges [{0x0041, 0x005A}, {0x0061, 0x007A}, {0x00C0, 0x024F}]

  @type script :: :zh | :ja | :ko | :latin | :other

  @doc """
  Detect the dominant script family of `text`.

  Returns `:other` for empty or ambiguous text.
  """
  @spec script(String.t()) :: script()
  def script(text) when is_binary(text) do
    cond do
      ratio(text, @kana_ranges) >= 0.2 ->
        :ja

      ratio(text, @hangul_ranges) >= 0.4 ->
        :ko

      ratio(text, @cjk_ranges) >= 0.5 and ratio(text, @kana_ranges) < 0.05 ->
        :zh

      ratio(text, @latin_ranges) >= 0.3 ->
        :latin

      true ->
        :other
    end
  end

  def script(_), do: :other

  @doc """
  Map a detected script to a conventional BCP-47 language tag, or `nil`
  for `:other`.
  """
  @spec to_lang(script()) :: String.t() | nil
  def to_lang(:zh), do: "zh"
  def to_lang(:ja), do: "ja"
  def to_lang(:ko), do: "ko"
  def to_lang(:latin), do: "en"
  def to_lang(:other), do: nil

  @doc """
  Ratio of characters falling into `ranges` (list of `{first, last}` code
  points). 0.0 for empty text.
  """
  @spec ratio(String.t(), [{non_neg_integer(), non_neg_integer()}]) :: float()
  def ratio(text, ranges) do
    chars = String.to_charlist(text)
    total = length(chars)

    if total == 0 do
      0.0
    else
      matching = Enum.count(chars, fn c -> Enum.any?(ranges, &in_range?(c, &1)) end)
      matching / total
    end
  end

  defp in_range?(c, {first, last}), do: c >= first and c <= last
end
