defmodule Earss.Admin.Controllers.Translate do
  @moduledoc false

  import Ecto.Query, warn: false
  import Earss.Admin.Helpers
  import Earss.Admin.ControllerHelpers

  alias Earss.Admin.Views.Translate, as: View
  alias Earss.Feeds.Feed
  alias Earss.Reader.Subscription
  alias Earss.Repo
  alias Earss.Translate.Registry

  def index(conn) do
    with_user(conn, fn conn ->
      user = conn.assigns.admin_user

      translators = Registry.list_translators()

      enabled_feeds =
        from(f in Feed, where: not is_nil(f.translate_to), order_by: [asc: f.title])
        |> Repo.all()

      enabled_subs =
        from(s in Subscription,
          where: not is_nil(s.translate_to),
          preload: [:feed],
          order_by: [asc: s.id]
        )
        |> Repo.all()

      html(
        conn,
        View.index(user, flash(conn), %{
          translators: translators,
          enabled_feeds: enabled_feeds,
          enabled_subs: enabled_subs
        })
      )
    end)
  end
end
