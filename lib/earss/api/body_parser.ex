defmodule Earss.API.BodyParser do
  @moduledoc """
  Plug.Parsers wrapper that converts oversized bodies into a 413.

  Plug.Parsers raises RequestTooLargeError when a body exceeds the parser
  length limit; with no error handler in the pipeline the exception
  propagated to Bandit and produced a 500 (triggerable unauthenticated).
  This wrapper rescues only that error — everything else keeps the
  previous behaviour.
  """

  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    Plug.Parsers.call(conn, Plug.Parsers.init(opts))
  rescue
    _e in Plug.Parsers.RequestTooLargeError ->
      conn
      |> send_resp(413, "request too large")
      |> halt()
  end
end
