defmodule Earss.TTS.Text do
  @moduledoc """
  Readable-text extraction for synthesis: turns an entry's title + HTML
  content into the plain text a TTS provider should speak.

  The host treats entry content as opaque HTML; here it is flattened to
  text (tags dropped, entities decoded, whitespace collapsed) because the
  provider contract takes plain `text`. Providers may apply their own
  chunking/normalisation on top.
  """

  alias Earss.Feeds.Entry

  @doc """
  Speakable text for an entry, or `:no_text` when there is nothing worth
  reading (no title and no body).
  """
  @spec from_entry(Entry.t()) :: {:ok, String.t()} | :no_text
  def from_entry(%Entry{} = entry) do
    title = String.trim(entry.title || "")
    body = html_to_text(entry.content || entry.summary || "")

    text = Enum.reject([title, body], &(&1 == "")) |> Enum.join("\n\n")

    if text == "", do: :no_text, else: {:ok, String.trim(text)}
  end

  def from_entry(_), do: :no_text

  @doc """
  Flatten HTML to plain text: tags dropped, entities decoded, runs of
  whitespace collapsed to single spaces (block boundaries become newlines
  so sentences do not glue together).
  """
  @spec html_to_text(String.t()) :: String.t()
  def html_to_text(html) when is_binary(html) do
    case Floki.parse_fragment(html) do
      {:ok, nodes} ->
        nodes
        |> Floki.text(sep: " ")
        |> String.replace(~r/\s+/, " ")
        |> String.trim()

      _ ->
        ""
    end
  end

  def html_to_text(_), do: ""
end
