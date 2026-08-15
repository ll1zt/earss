defmodule Earss.API.Router do
  @moduledoc """
  HTTP entry: health, JSON API, Fever, Admin UI.

  Mounted by Bandit when `config :earss, :api, enabled: true`.
  """

  use Plug.Router

  alias Earss.API.{JSON, Token}
  alias Earss.OperatorAuth

  plug(Plug.RequestId)
  plug(Plug.Logger)
  plug(:put_secret_key_base)

  # Admin assets (kami theme CSS/JS). The {:app, "priv/static"} tuple is
  # resolved at request time (Plug.Static) — a plain app_dir/2 call here
  # would be evaluated at compile time and bake the build-machine path into
  # the release (nix sandbox paths are gone at runtime → 404).
  plug(Plug.Static, at: "/static", from: {:earss, "priv/static"})

  # Runtime session wrapper: the :secure flag resolves per request (see
  # Earss.API.Session) — plug options here are evaluated at compile time,
  # which would bake the build-machine env into the release.
  plug(Earss.API.Session,
    store: :cookie,
    key: "_earss_admin_session",
    signing_salt: "earss_admin",
    same_site: "Lax",
    # Explicit for clarity (Plug defaults http_only to true).
    http_only: true,
    max_age: 60 * 60 * 24 * 14
  )

  plug(:fetch_session)
  plug(:match)

  # Cache raw body so GReader can recover repeated form keys (i=/a=/r=).
  # Plug.Conn.Query keeps only the last value for duplicate keys; NetNewsWire
  # posts many `i=tag:.../item/<hex>` fields in one contents/edit-tag request.
  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason,
    body_reader: {__MODULE__, :cache_raw_body, []}
  )

  plug(:dispatch)

  @doc false
  def cache_raw_body(conn, opts) do
    {:ok, body, conn} = Plug.Conn.read_body(conn, opts)
    conn = Plug.Conn.assign(conn, :raw_body, body)
    {:ok, body, conn}
  end

  get "/health" do
    JSON.json(conn, 200, %{status: "ok"})
  end

  get "/" do
    conn
    |> put_resp_header("location", "/admin")
    |> send_resp(302, "")
  end

  forward("/fever", to: Earss.API.Fever)

  # FreshRSS / Google Reader API (NetNewsWire "FreshRSS" account type)
  # Register before generic /api forward. Accept with and without .php.
  forward("/api/greader.php", to: Earss.API.GReader)
  forward("/api/greader", to: Earss.API.GReader)

  forward("/admin", to: Earss.Admin.Router)

  post "/api/auth/login" do
    ip = Earss.RateLimit.client_ip(conn)
    password = param(conn, "password")

    if OperatorAuth.verify_admin_password(password || "") do
      Earss.RateLimit.clear(:api_login, ip)
      token = Token.sign_operator()
      JSON.json(conn, 200, %{token: token, user: %{username: "earss"}})
    else
      case Earss.RateLimit.failure(:api_login, ip) do
        :ok -> JSON.error(conn, 401, "invalid_credentials")
        {:error, :rate_limited} -> JSON.error(conn, 429, "rate_limited")
      end
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
