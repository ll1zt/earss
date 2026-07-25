defmodule Earss.Admin.Controllers.Settings do
  @moduledoc false

  import Earss.Admin.Helpers
  import Earss.Admin.ControllerHelpers

  alias Earss.Admin.Views.Settings, as: View
  alias Earss.Reader

  def index(conn) do
    with_user(conn, fn conn ->
      user = conn.assigns.admin_user
      fever_url = base_url(conn.scheme, conn.host, conn.port) <> "/fever/"
      html(conn, View.page(user, flash(conn), fever_url))
    end)
  end

  def update_password(conn) do
    with_user(conn, fn conn ->
      user = conn.assigns.admin_user
      pass = bp(conn, "password") || ""
      pass2 = bp(conn, "password_confirm") || ""

      cond do
        String.length(pass) < 4 ->
          conn |> put_flash(:err, "Password too short") |> redirect("/admin/settings")

        pass != pass2 ->
          conn |> put_flash(:err, "Passwords do not match") |> redirect("/admin/settings")

        true ->
          case Reader.set_password(user, pass) do
            {:ok, _} ->
              conn
              |> put_flash(:ok, "Password updated (Fever key recomputed from new password)")
              |> redirect("/admin/settings")

            {:error, reason} ->
              conn
              |> put_flash(:err, "Update failed: #{format_error(reason)}")
              |> redirect("/admin/settings")
          end
      end
    end)
  end

  def update_fever(conn) do
    with_user(conn, fn conn ->
      user = conn.assigns.admin_user
      secret = bp(conn, "fever_secret") || ""

      if String.trim(secret) == "" do
        conn |> put_flash(:err, "Secret required") |> redirect("/admin/settings")
      else
        case Reader.set_fever_password(user, secret) do
          {:ok, _} ->
            conn
            |> put_flash(
              :ok,
              "Fever secret set. In NetNewsWire use username + this secret as password."
            )
            |> redirect("/admin/settings")

          {:error, reason} ->
            conn
            |> put_flash(:err, "Failed: #{format_error(reason)}")
            |> redirect("/admin/settings")
        end
      end
    end)
  end
end
