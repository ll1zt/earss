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

    case Earss.RateLimit.check(:admin_login, ip) do
      :ok ->
        password = bp(conn, "password")

        conn = Auth.login(conn, password)

        if Auth.login_success?(conn) do
          conn
          |> put_flash(:ok, "Signed in")
          |> redirect("/admin")
        else
          Earss.RateLimit.report_failure(:admin_login, ip)

          msg =
            if OperatorAuth.admin_password() == nil do
              "Admin password is not configured — set ADMIN_PASSWORD in earss.env and restart the app."
            else
              "Invalid password"
            end

          html(conn, View.login_page(nil, msg))
        end

      {:error, :rate_limited} ->
        html(conn, View.login_page(nil, "Too many login attempts — try again in a few minutes."))
    end
  end

  def delete(conn) do
    conn
    |> Auth.logout()
    |> redirect("/admin/login")
  end
end
