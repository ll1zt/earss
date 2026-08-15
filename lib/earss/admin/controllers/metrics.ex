defmodule Earss.Admin.Controllers.Metrics do
  @moduledoc false

  import Earss.Admin.Helpers
  import Earss.Admin.ControllerHelpers

  alias Earss.Admin.Views.Metrics, as: View

  def index(conn) do
    with_user(conn, fn conn ->
      user = conn.assigns.admin_user

      html(conn, View.index(user, flash(conn), Earss.Telemetry.Store.snapshot()))
    end)
  end

  def reset(conn) do
    with_user(conn, fn conn ->
      :ok = Earss.Telemetry.Store.reset()
      conn |> put_flash(:ok, "Metrics reset") |> redirect("/admin/metrics")
    end)
  end
end
