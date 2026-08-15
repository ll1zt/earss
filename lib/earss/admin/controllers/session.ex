defmodule Earss.Admin.Controllers.Session do
  @moduledoc false

  import Earss.Admin.Helpers

  alias Earss.Admin.Auth
  alias Earss.Admin.Views.Session, as: View
  alias Earss.OperatorAuth

  def new(conn) do
    if conn.assigns.admin_user do
      redirect(conn, "/admin")
    else
      html(conn, View.login_page(flash(conn)))
    end
  end

  def create(conn) do
    ip = Earss.RateLimit.client_ip(conn)
    password = bp(conn, "password")

    conn = Auth.login(conn, password)

    if Auth.login_success?(conn) do
      # A correct credential always wins and clears any lock (an attacker
      # must never be able to lock the operator out).
      Earss.RateLimit.clear(:admin_login, ip)

      conn
      |> put_flash(:ok, "Signed in")
      |> redirect("/admin")
    else
      msg =
        if OperatorAuth.admin_password() == nil do
          "Admin password is not configured — set ADMIN_PASSWORD in earss.env and restart the app."
        else
          "Invalid password"
        end

      case Earss.RateLimit.failure(:admin_login, ip) do
        :ok ->
          html(conn, View.login_page(nil, msg))

        {:error, :rate_limited} ->
          html(
            conn,
            View.login_page(nil, "Too many login attempts — try again in a few minutes.")
          )
      end
    end
  end

  def delete(conn) do
    conn
    |> Auth.logout()
    |> redirect("/admin/login")
  end
end
