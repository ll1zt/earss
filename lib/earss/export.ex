defmodule Earss.Export do
  @moduledoc """
  Export reader content as downloadable files.

  A service context that composes global content (`Earss.Feeds`) with
  the operator's reading state (`Earss.Reader`) into flat, streamable rows:

    * `starred/1` — the operator's starred entries
    * `feed/2` — every entry of a subscribed feed
    * `all/1` — every entry on the instance (full archive)

  Rows are lazy `Ecto.Adapters.SQL.Stream`s (batched, O(1) memory).
  Serialization to JSON or Markdown lives in `Earss.Export.Render`;
  chunked HTTP delivery in `Earss.Export.Download`.

  ## Formats

  | Format | Content |
  |--------|---------|
  | `:json` | Self-describing object `{"scope","generated","entries":[...]}` — lossless |
  | `:markdown` | One block per entry; bodies are plain text (HTML stripped) |

  ## Row shape

  Every export row is a flat map with feed context plus entry fields:

      %{
        feed_id: integer, feed_title: String.t() | nil, feed_link: String.t(),
        site_url: String.t() | nil, feed_type: String.t(),
        entry_id: integer, link: String.t(), guid: String.t(),
        title: String.t() | nil, author: String.t() | nil,
        summary: String.t() | nil, content: String.t() | nil,
        published_at: DateTime.t() | nil, inserted_at: DateTime.t(),
        is_read: boolean() | nil, is_star: boolean() | nil, read_at: DateTime.t() | nil
      }
  """

  alias Earss.Export.{Download, Query, Render}
  alias Earss.Reader.AnchorUser
  alias Earss.Repo

  @type format :: :json | :markdown

  @doc """
  Lazy stream of the operator's starred entries (newest first).

  Includes entries from hidden subscriptions: an explicit star is the
  operator's intent regardless of feed visibility.
  """
  @spec starred(keyword()) :: Enumerable.t()
  def starred(opts \\ []) do
    stream(Query.starred(AnchorUser.id()), opts)
  end

  @doc """
  Lazy stream of every entry of a feed the operator is subscribed to.

  Returns `{:ok, feed, stream}` or `{:error, :not_found}`.
  """
  @spec feed(term(), keyword()) ::
          {:ok, map(), Enumerable.t()} | {:error, :not_found}
  def feed(feed_id, opts \\ []) do
    case Query.find_subscribed_feed(feed_id) do
      nil ->
        {:error, :not_found}

      feed ->
        {:ok, feed, stream(Query.feed(AnchorUser.id(), feed_id), opts)}
    end
  end

  @doc """
  Lazy stream of every entry on the instance (admin archive).

  Callers must enforce admin authorization; the query itself is global.
  """
  @spec all(keyword()) :: Enumerable.t()
  def all(opts \\ []) do
    stream(Query.all(), opts)
  end

  @doc """
  Serialize a row stream to lazy iodata chunks for a format.

  See `Earss.Export.Render` for the `opts` (`:scope`, `:user`, `:feed`).
  """
  @spec chunks(format(), Enumerable.t(), keyword()) :: Enumerable.t()
  def chunks(format, stream, opts \\ []) when format in [:json, :markdown] do
    Render.chunks(format, stream, opts)
  end

  @doc """
  Send a row stream as a chunked attachment download (Plug).

  See `Earss.Export.Download` for the `opts`.
  """
  @spec send_download(Plug.Conn.t(), format(), Enumerable.t(), keyword()) :: Plug.Conn.t()
  def send_download(conn, format, stream, opts) when format in [:json, :markdown] do
    Download.send(conn, format, stream, opts)
  end

  defp stream(query, opts) do
    max_rows = Keyword.get(opts, :max_rows, 1_000)
    Repo.stream(query, max_rows: max_rows)
  end
end
