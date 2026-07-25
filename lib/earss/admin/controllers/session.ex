defmodule Earss.Admin.Controllers.Session do
  @moduledoc false

  import Earss.Admin.Helpers

  alias Earss.Admin.Auth
  alias Earss.Admin.Views.Session, as: View
  alias Earss.Reader

  def new(conn) do
    if conn.assigns.admin_user do
      redirect(conn, "/admin")
    else
      html(conn, View.login_page(flash(conn)))
    end
  end

  def create(conn) do
    username = bp(conn, "username")
    password = bp(conn, "password")

    case Reader.authenticate_user(username || "", password || "") do
      {:ok, user} ->
        conn
        |> Auth.login(user)
        |> put_flash(:ok, "Signed in as #{user.username}")
        |> redirect("/admin")

      {:error, _} ->
        html(conn, View.login_page(nil, "Invalid username or password"))
    end
  end

  def delete(conn) do
    conn
    |> Auth.logout()
    |> redirect("/admin/login")
  end
end
