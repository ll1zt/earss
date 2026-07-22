defmodule Earss.API.Router do
  @moduledoc """
  HTTP entry: health, JSON API, Fever, Admin UI.

  Mounted by Bandit when `config :earss, :api, enabled: true`.
  """

  use Plug.Router

  alias Earss.API.{JSON, Token, Views}
  alias Earss.Reader

  plug(Plug.RequestId)
  plug(Plug.Logger)
  plug(:put_secret_key_base)

  plug(Plug.Session,
    store: :cookie,
    key: "_earss_admin_session",
    signing_salt: "earss_admin",
    same_site: "Lax",
    max_age: 60 * 60 * 24 * 14
  )

  plug(:fetch_session)
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

  get "/" do
    conn
    |> put_resp_header("location", "/admin")
    |> send_resp(302, "")
  end

  forward("/fever", to: Earss.API.Fever)
  forward("/admin", to: Earss.Admin.Router)

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

  defp put_secret_key_base(conn, _opts) do
    secret =
      Application.get_env(:earss, :api, [])
      |> Keyword.get(:secret_key_base) ||
        raise "config :earss, :api, secret_key_base is not set"

    %{conn | secret_key_base: secret}
  end

  defp param(conn, key) do
    case conn.body_params do
      %{} = params -> Map.get(params, key) || Map.get(params, String.to_atom(key))
      _ -> nil
    end
  end
end
