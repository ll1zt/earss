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

  @doc "Max feeds per batch action (mirrored in the index view hint)."
  def batch_limit, do: 50

  # Batch management: re-translate or publish (original language) the pending
  # entries of the selected enabled feeds.
  def batch(conn) do
    with_user(conn, fn conn ->
      ids = batch_ids(conn)
      action = bp(conn, "action")

      if ids == [] do
        conn
        |> put_flash(:err, "No feeds selected")
        |> redirect("/admin/translate")
      else
        {ok_n, fail_n, notes} = run_batch(ids, action)

        msg =
          "Batch #{action || "?"}: #{ok_n} ok, #{fail_n} failed" <>
            if(notes == [], do: "", else: " — " <> Enum.join(Enum.take(notes, 3), "; "))

        type = if fail_n > 0 and ok_n == 0, do: :err, else: :ok

        conn
        |> put_flash(type, msg)
        |> redirect("/admin/translate")
      end
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

  defp batch_ids(conn) do
    raw =
      case conn.body_params do
        %{"ids" => ids} -> ids
        %{"ids[]" => ids} -> ids
        _ -> []
      end

    raw
    |> List.wrap()
    |> Enum.map(&parse_int/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.take(batch_limit())
  end

  defp run_batch(ids, action) do
    from(f in Feed, where: f.id in ^ids)
    |> Repo.all()
    |> Enum.reduce({0, 0, []}, fn feed, {ok_n, fail_n, notes} ->
      case do_batch_action(feed, action) do
        :ok ->
          {ok_n + 1, fail_n, notes}

        {:error, reason} ->
          {ok_n, fail_n + 1, ["##{feed.id}: #{format_error(reason)}" | notes]}
      end
    end)
    |> then(fn {ok_n, fail_n, notes} -> {ok_n, fail_n, Enum.reverse(notes)} end)
  end

  defp do_batch_action(feed, "retry"), do: Earss.Enrichment.retry_paused(feed)
  defp do_batch_action(feed, "publish"), do: Earss.Enrichment.publish_pending(feed)

  defp do_batch_action(_feed, action) when is_binary(action),
    do: {:error, {:unknown_action, action}}

  defp do_batch_action(_feed, _action), do: {:error, :missing_action}
end
