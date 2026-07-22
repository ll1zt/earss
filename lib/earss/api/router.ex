defmodule Earss.API.Router do
  @moduledoc """
  HTTP entry: health, JSON API, Fever compatibility.

  Mounted by Bandit when `config :earss, :api, enabled: true`.
  """

  use Plug.Router

  alias Earss.API.{JSON, Token, Views}
  alias Earss.Reader

  plug(Plug.RequestId)
  plug(Plug.Logger)
  plug(:match)

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason
  )

  plug(:dispatch)

  get "/health" do
    JSON.json(conn, 200, %{status: "ok"})
  end

  # Fever (NetNewsWire etc.) — form or query API
  forward("/fever", to: Earss.API.Fever)

  post "/api/auth/login" do
    username = param(conn, "username")
    password = param(conn, "password")

    case Reader.authenticate_user(username || "", password || "") do
      {:ok, user} ->
        token = Token.sign(user.id)
        JSON.json(conn, 200, %{token: token, user: Views.user(user)})

      {:error, _} ->
        JSON.error(conn, 401, "invalid_credentials")
    end
  end

  forward("/api", to: Earss.API.AuthenticatedRouter)

  match _ do
    JSON.error(conn, 404, "not_found")
  end

  defp param(conn, key) do
    case conn.body_params do
      %{} = params -> Map.get(params, key) || Map.get(params, String.to_atom(key))
      _ -> nil
    end
  end
end
