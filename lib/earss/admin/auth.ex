defmodule Earss.Admin.Auth do
  @moduledoc false

  import Plug.Conn
  alias Earss.Reader

  def init(opts), do: opts

  def call(conn, _opts) do
    user_id = get_session(conn, :admin_user_id)

    user =
      case user_id do
        nil -> nil
        id -> Reader.get_user(id)
      end

    user =
      case user do
        %{is_active: true} = u -> u
        _ -> nil
      end

    assign(conn, :admin_user, user)
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

  @doc """
  Require a logged-in user with `user_type == \"admin\"`.
  Redirects non-admins to dashboard with a flash via session.
  """
  def require_admin(conn, _opts \\ []) do
    conn = require_user(conn, [])
    if conn.halted, do: conn, else: check_admin(conn)
  end

  defp check_admin(conn) do
    case conn.assigns[:admin_user] do
      %{user_type: "admin"} ->
        conn

      _ ->
        conn
        |> put_session(:admin_flash, {:err, "Admin privileges required"})
        |> put_resp_header("location", "/admin")
        |> send_resp(302, "")
        |> halt()
    end
  end

  def admin?(%{user_type: "admin"}), do: true
  def admin?(_), do: false

  def login(conn, user) do
    conn
    |> put_session(:admin_user_id, user.id)
    |> configure_session(renew: true)
  end

  def logout(conn) do
    conn
    |> configure_session(drop: true)
  end
end
