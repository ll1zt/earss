defmodule Earss.Export.Render.Markdown do
  @moduledoc false

  @block_marker ~r/^\s*((\#{1,6})\s|>\s?|[-+*]\s|\d+\.\s)/

  @doc """
  Markdown document header describing the export scope.
  """
  @spec header(keyword()) :: iodata()
  def header(opts) do
    scope = Keyword.get(opts, :scope, "export")
    user = Keyword.get(opts, :user)
    feed = Keyword.get(opts, :feed)
    generated = DateTime.utc_now() |> DateTime.truncate(:second)

    """
    # Earss export

    - Scope: #{escape_inline(scope)}
    #{if user, do: "- User: #{escape_inline(user)}\n", else: ""}#{if feed, do: "- Feed: #{escape_inline(feed_title(feed))} (#{escape_inline(feed_link(feed))})\n", else: ""}- Generated: #{escape_inline(to_string(generated))} UTC

    ---

    """
  end

  @doc """
  One markdown block for an export row.

  Bodies are plain text: HTML is stripped (`Floki.text`), and markdown block
  markers at line starts are escaped so the content cannot restructure the
  document.
  """
  @spec row(map()) :: iodata()
  def row(row) do
    title = row.title |> blank_to_nil() |> to_string() |> collapse_ws()
    title = if title == "", do: "(no title)", else: title
    published = row.published_at && to_string(row.published_at)
    author_line = author_line(row.author)
    body = plain_text(row.content || row.summary || "")

    """
    ## #{escape_inline(title)}

    - Link: #{escape_inline(to_string(row.link))}
    - Source: #{escape_inline(feed_label(row))}
    - Published: #{escape_inline(published || "—")}#{author_line}

    #{escape_block(body)}

    """
  end

  defp author_line(author) do
    case blank_to_nil(author) do
      nil -> ""
      name -> "\n- Author: #{escape_inline(collapse_ws(to_string(name)))}"
    end
  end

  defp feed_label(row) do
    title = row.feed_title |> blank_to_nil() |> to_string() |> collapse_ws()
    link = row.feed_link |> blank_to_nil() |> to_string()

    if title == "" do
      link
    else
      "#{title} (#{link})"
    end
  end

  defp feed_title(%{title: title}) when is_binary(title) and title != "", do: title
  defp feed_title(%{title: title}), do: title
  defp feed_title(_), do: ""
  defp feed_link(%{link: link}) when is_binary(link), do: link
  defp feed_link(_), do: ""

  defp plain_text(nil), do: ""
  defp plain_text(""), do: ""

  defp plain_text(html) do
    case Floki.parse_fragment(html) do
      {:ok, tree} -> tree |> Floki.text() |> String.trim()
      {:error, _} -> String.trim(html)
    end
  end

  @doc """
  Escape characters that would alter the document structure: backslashes and
  backticks inline, and common block markers at line starts.
  """
  @spec escape_block(String.t()) :: String.t()
  def escape_block(text) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", fn line ->
      if Regex.match?(@block_marker, line), do: "\\" <> line, else: line
    end)
  end

  defp escape_inline(value) do
    value
    |> to_string()
    |> String.replace("\\", "\\\\")
    |> String.replace("`", "\\`")
  end

  defp collapse_ws(value) when is_binary(value),
    do: String.replace(value, ~r/\s+/, " ") |> String.trim()

  defp collapse_ws(other), do: other

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
