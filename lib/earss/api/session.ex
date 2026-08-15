defmodule Earss.API.Session do
  @moduledoc """
  Plug.Session wrapper that resolves the `:secure` cookie flag at request
  time.

  Plug.Builder evaluates plug options when the router module compiles, so a
  runtime env knob (HTTP_COOKIE_SECURE) cannot be read there — it would bake
  the build-machine value into the release. This wrapper re-runs
  Plug.Session.init/1 per request (cheap keyword processing) with the
  runtime-resolved flag; the rest of the options stay static.
  """

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    opts = Keyword.put(opts, :secure, secure?())
    Plug.Session.call(conn, Plug.Session.init(opts))
  end

  @doc "Env HTTP_COOKIE_SECURE wins over config :earss, :api, :cookie_secure."
  def secure? do
    case System.get_env("HTTP_COOKIE_SECURE") do
      nil ->
        Application.get_env(:earss, :api, [])
        |> Keyword.get(:cookie_secure, false)

      v ->
        v in ["1", "true", "yes", "on"]
    end
  end
end
