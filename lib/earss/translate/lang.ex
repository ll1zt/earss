defmodule Earss.Translate.Lang do
  @moduledoc """
  Conservative local heuristics for deciding whether text is already written
  in the target language, so the host can skip an API call.

  Only skips when the script evidence is strong (e.g. a feed already mostly in
  Chinese is not sent to a `zh` translator). The plugin's own `skip?/2` and the
  LLM remain the final arbiters for ambiguous text.
  """

  @cjk_ranges [{0x3400, 0x4DBF}, {0x4E00, 0x9FFF}]
  @kana_ranges [{0x3040, 0x309F}, {0x30A0, 0x30FF}]
  @hangul_ranges [{0xAC00, 0xD7AF}]

  @doc """
  True when `text` is already predominantly in `target_lang`.

  Unsupported targets never skip (`false`). Short samples are skipped only on
  very strong evidence (the ratio is required over the whole text).
  """
  @spec skip?(String.t(), String.t()) :: boolean()
  def skip?(text, target) when is_binary(text) do
    case String.downcase(target) do
      "zh" -> ratio(text, @cjk_ranges) >= 0.5
      "ja" -> ratio(text, @kana_ranges) >= 0.4
      "ko" -> ratio(text, @hangul_ranges) >= 0.4
      _ -> false
    end
  end

  def skip?(_, _), do: false

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
