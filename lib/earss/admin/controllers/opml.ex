defmodule Earss.Admin.Controllers.OPML do
  @moduledoc false

  import Plug.Conn
  import Earss.Admin.Helpers
  import Earss.Admin.ControllerHelpers

  alias Earss.Admin.Views.OPML, as: View
  alias Earss.Reader

  def index(conn) do
    with_user(conn, fn conn ->
      user = conn.assigns.admin_user
      html(conn, View.page(user, flash(conn)))
    end)
  end

  def export(conn) do
    with_user(conn, fn conn ->
      user = conn.assigns.admin_user

      case Reader.export_opml() do
        {:ok, xml} ->
          conn
          |> put_resp_content_type("text/x-opml+xml")
          |> put_resp_header(
            "content-disposition",
            "attachment; filename=\"earss-#{user.username}.opml\""
          )
          |> send_resp(200, xml)
      end
    end)
  end

  def import(conn) do
    with_user(conn, fn conn ->
      xml = bp(conn, "opml") || ""

      case Reader.import_opml(xml, refresh: false) do
        {:ok, stats} ->
          conn
          |> put_flash(
            :ok,
            "Import done: #{stats.imported} imported, #{stats.skipped} skipped, #{stats.errors} errors"
          )
          |> redirect("/admin/opml")

        {:error, reason} ->
          conn
          |> put_flash(:err, "Import failed: #{format_error(reason)}")
          |> redirect("/admin/opml")
      end
    end)
  end
end
