defmodule Earss.Admin.Controllers.Translate do
  @moduledoc false

  import Ecto.Query, warn: false
  import Earss.Admin.Helpers
  import Earss.Admin.ControllerHelpers

  alias Earss.Admin.Views.Translate, as: View
  alias Earss.Feeds.Feed
  alias Earss.Reader.Subscription
  alias Earss.Repo
  alias Earss.Enrichment.Registry

  def index(conn) do
    with_user(conn, fn conn ->
      user = conn.assigns.admin_user

      translators = Registry.list_enrichers()

      enabled_feeds =
        from(f in Feed,
          where: not is_nil(f.translate_to),
          # only feeds that still have (active) subscribers — an unsubscribed
          # feed keeps its translate_to config but must not appear here
          where: fragment("EXISTS (SELECT 1 FROM subscriptions s WHERE s.feed_id = ?)", f.id),
          order_by: [asc: f.title]
        )
        |> Repo.all()
        |> Enum.map(fn feed -> Map.put(feed, :stats, Earss.Enrichment.stats(feed)) end)

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
