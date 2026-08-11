defmodule Earss.Export.Download do
  @moduledoc false

  import Plug.Conn

  alias Earss.Repo

  @doc """
  Send a row stream as a chunked attachment download.

  The row stream is consumed inside a read-only `Repo.transaction`: Ecto
  `Repo.stream` batches hold a connection across batch boundaries, which the
  SQL Sandbox (tests) requires, and the snapshot keeps the export consistent.

  `opts`:

    * `:base` — filename base (sanitized; date and extension appended)
    * `:scope`, `:user`, `:feed` — forwarded to `Earss.Export.Render` for
      document metadata
  """
  @spec send(Plug.Conn.t(), Earss.Export.format(), Enumerable.t(), keyword()) :: Plug.Conn.t()
  def send(conn, format, stream, opts) when format in [:json, :markdown] do
    {type, charset} = content_type(format)

    conn =
      conn
      |> put_resp_content_type(type, charset)
      |> put_resp_header("content-disposition", attachment_header(format, opts))
      |> send_chunked(200)

    {:ok, conn} =
      Repo.transaction(fn -> write_chunks(conn, Earss.Export.chunks(format, stream, opts)) end)

    conn
  end

  defp write_chunks(conn, chunks) do
    # A client aborting a download is expected — stop writing, keep the
    # (read-only) transaction clean instead of raising mid-stream.
    Enum.reduce_while(chunks, conn, fn chunk, conn ->
      case chunk(conn, chunk) do
        {:ok, conn} -> {:cont, conn}
        {:error, :closed} -> {:halt, conn}
      end
    end)
  end

  defp content_type(:json), do: {"application/json", "utf-8"}
  defp content_type(:markdown), do: {"text/markdown", "utf-8"}

  defp attachment_header(format, opts) do
    base = opts |> Keyword.get(:base, "earss-export") |> slugify()
    date = Date.utc_today() |> to_string()
    extension = if format == :markdown, do: "md", else: "json"

    ~s(attachment; filename="#{base}-#{date}.#{extension}")
  end

  defp slugify(value) when is_binary(value) do
    case String.replace(value, ~r/[^A-Za-z0-9._-]/, "_") |> String.trim("_") do
      "" -> "earss-export"
      other -> other
    end
  end

  defp slugify(_), do: "earss-export"
end
