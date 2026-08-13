defmodule Earss.Admin.Controllers.Settings do
  @moduledoc false

  import Earss.Admin.Helpers
  import Earss.Admin.ControllerHelpers

  alias Earss.Admin.Views.Settings, as: View

  def index(conn) do
    with_user(conn, fn conn ->
      operator = conn.assigns.admin_user
      fever_url = base_url(conn.scheme, conn.host, conn.port) <> "/fever/"
      html(conn, View.page(operator, flash(conn), fever_url))
    end)
  end
end
