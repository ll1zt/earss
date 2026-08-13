defmodule Earss.Admin.Auth do
  @moduledoc false

  import Plug.Conn
  alias Earss.OperatorAuth

  def init(opts), do: opts

  def call(conn, _opts) do
    operator =
      case get_session(conn, :admin_authenticated) do
        true -> OperatorAuth.operator()
        _ -> nil
      end

    assign(conn, :admin_user, operator)
  end

  def require_user(conn, _opts) do
    if conn.assigns[:admin_user] do
      conn
    else
      conn
      |> put_resp_header("location", "/admin/login")
      |> send_resp(302, "")
      |> halt()
    end
  end

  def login(conn, password) do
    case OperatorAuth.verify_admin_password(password || "") do
      true ->
        conn
        |> put_session(:admin_authenticated, true)
        |> configure_session(renew: true)

      false ->
        conn
    end
  end

  def login_success?(conn), do: get_session(conn, :admin_authenticated) == true

  def logout(conn) do
    conn
    |> configure_session(drop: true)
  end
end
