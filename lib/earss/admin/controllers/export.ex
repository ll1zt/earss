defmodule Earss.Admin.Controllers.Export do
  @moduledoc false

  import Earss.Admin.Helpers
  import Earss.Admin.ControllerHelpers

  alias Earss.Admin.Views.Export, as: View
  alias Earss.Export

  def index(conn) do
    with_user(conn, fn conn ->
      user = conn.assigns.admin_user
      html(conn, View.page(user, flash(conn)))
    end)
  end

  def starred(conn) do
    with_user(conn, fn conn ->
      Export.send_download(conn, format(conn), Export.starred(),
        base: "earss-starred",
        scope: "starred"
      )
    end)
  end

  def all(conn) do
    with_admin(conn, fn conn ->
      Export.send_download(conn, format(conn), Export.all(),
        base: "earss-all",
        scope: "all"
      )
    end)
  end

  defp format(conn) do
    case conn.query_params["format"] do
      "markdown" -> :markdown
      "md" -> :markdown
      _ -> :json
    end
  end
end
