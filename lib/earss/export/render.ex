defmodule Earss.Export.Render do
  @moduledoc """
  Serializers for export rows (`Earss.Export`).

  `chunks/3` turns a lazy row stream into a lazy stream of iodata chunks:

    * `:json` — a self-describing object `{"scope","user","generated","entries":[...]}`
      written incrementally (one entry per chunk)
    * `:markdown` — a header plus one block per entry; HTML bodies are
      stripped to plain text and markdown block markers are escaped
  """

  alias Earss.Export.Render.JSON
  alias Earss.Export.Render.Markdown

  @doc """
  Lazy iodata chunks for `format` from a row stream.

  `opts` (passed to the header / used for JSON metadata):

    * `:scope` — `"starred"` | `"feed"` | `"all"` (string)
    * `:user` — exporting username, if any
    * `:feed` — `%{title: ..., link: ...}` for feed-scope exports
  """
  @spec chunks(Earss.Export.format(), Enumerable.t(), keyword()) :: Enumerable.t()
  def chunks(:json, stream, opts) do
    rows =
      stream
      |> Stream.with_index()
      |> Stream.map(fn {row, index} -> JSON.row(row, index) end)

    Stream.concat([[JSON.head(opts)], rows, ["]}\n"]])
  end

  def chunks(:markdown, stream, opts) do
    Stream.concat([[Markdown.header(opts)], Stream.map(stream, &Markdown.row/1), ["\n---\n"]])
  end
end
