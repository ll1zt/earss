defmodule Earss.Admin.Controllers.Session do
  @moduledoc false

  import Earss.Admin.Helpers

  alias Earss.Admin.Auth
  alias Earss.Admin.Views.Session, as: View

  def new(conn) do
    if conn.assigns.admin_user do
      redirect(conn, "/admin")
    else
      html(conn, View.login_page(flash(conn)))
    end
  end

  def create(conn) do
    password = bp(conn, "password")

    conn = Auth.login(conn, password)

    if Auth.login_success?(conn) do
      conn
      |> put_flash(:ok, "Signed in")
      |> redirect("/admin")
    else
      html(conn, View.login_page(nil, "Invalid password"))
    end
  end

  def delete(conn) do
    conn
    |> Auth.logout()
    |> redirect("/admin/login")
  end
end
