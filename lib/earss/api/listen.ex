defmodule Earss.API.Listen do
  @moduledoc """
  `GET /tts/listen/:entry_id?sig=…` — records a "listen to this article"
  request coming from the control injected into article content
  (`Earss.API.ListenControls`).

  Unauthenticated by design: the link is opened in the *reader's* browser,
  where no earss session exists. The signed token in the URL stands in for
  the session (see `Earss.TTS.Link`) — forging or enumerating ids requires
  `SECRET_KEY_BASE`.

  Responses are deliberately tiny static HTML pages: this is a redirect
  target, not a UI.
  """

  import Plug.Conn

  alias Earss.Feeds
  alias Earss.TTS
  alias Earss.TTS.Link

  def handle(conn) do
    case Link.verify(conn.params["sig"]) do
      :error ->
        page(conn, 403, "This listen link is not valid.")

      {:ok, entry_id} ->
        case TTS.record_request(entry_id) do
          {:ok, _request} ->
            body = [
              "<h1>Added to your listening queue</h1>",
              "<p>",
              Plug.HTML.html_escape_to_iodata(entry_title(Feeds.get_entry(entry_id))),
              "</p>"
            ]

            page(conn, 200, body)

          {:error, :unknown_entry} ->
            page(conn, 404, "Article not found.")
        end
    end
  end

  defp entry_title(%Feeds.Entry{title: title}) when is_binary(title), do: title
  defp entry_title(_), do: "(untitled)"

  defp page(conn, status, body) do
    doc = ["<!doctype html><meta charset=\"utf-8\"><title>earss · listen</title>", body]

    conn
    |> put_resp_content_type("text/html")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> send_resp(status, doc)
  end
end
