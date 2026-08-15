defmodule Earss.Admin.Controllers.Dashboard do
  @moduledoc false

  import Earss.Admin.Helpers
  import Earss.Admin.ControllerHelpers

  alias Earss.Admin.Views.Dashboard, as: View
  alias Earss.Feeds
  alias Earss.Reader

  def index(conn) do
    with_user(conn, fn conn ->
      user = conn.assigns.admin_user
      now = utc_now()
      subs = Reader.list_subscriptions(with_unread_count: true, include_hidden: true)
      unread = Enum.reduce(subs, 0, fn s, acc -> acc + (s.unread_count || 0) end)
      cats = Reader.list_categories()

      problem_subs =
        Enum.filter(subs, fn s ->
          f = s.feed
          f && (f.is_active == false or (is_integer(f.error_count) and f.error_count > 0))
        end)

      due_subs =
        Enum.filter(subs, fn s ->
          f = s.feed
          f && f.is_active && due_feed?(f, now)
        end)

      base = base_url(conn.scheme, conn.host, conn.port)
      recent = Feeds.list_recent_entries(12)
      telemetry = Earss.Telemetry.Store.snapshot()

      html(
        conn,
        View.page(user, flash(conn), %{
          subs: subs,
          cats: cats,
          unread: unread,
          problem_subs: problem_subs,
          due_subs: due_subs,
          recent: recent,
          telemetry: telemetry,
          fever_url: base <> "/fever/",
          greader_url: base <> "/api/greader.php"
        })
      )
    end)
  end
end
