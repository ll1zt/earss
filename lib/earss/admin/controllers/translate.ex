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

      # Batch stats and first-subscription lookups: ~2 queries total instead
      # of ~6 per feed.
      stats = Earss.Enrichment.stats_many(enabled_feeds)
      first_sub_ids = first_subscription_ids(Enum.map(enabled_feeds, & &1.id))

      enabled_feeds =
        Enum.map(enabled_feeds, fn feed ->
          feed
          |> Map.put(:stats, Map.get(stats, feed.id, %{}))
          |> Map.put(:first_sub_id, Map.get(first_sub_ids, feed.id, ""))
        end)

      html(
        conn,
        View.index(user, flash(conn), %{
          translators: translators,
          enabled_feeds: enabled_feeds
        })
      )
    end)
  end

  # Smallest subscription id per feed (a stable link target for the
  # "manage" buttons on the translate page).
  defp first_subscription_ids([]), do: %{}

  defp first_subscription_ids(feed_ids) do
    from(s in Subscription,
      where: s.feed_id in ^feed_ids,
      distinct: s.feed_id,
      order_by: [s.feed_id, s.id],
      select: {s.feed_id, s.id}
    )
    |> Repo.all()
    |> Map.new()
  end
end
