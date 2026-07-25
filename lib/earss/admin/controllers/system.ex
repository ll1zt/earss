defmodule Earss.Admin.Controllers.System do
  @moduledoc false

  import Ecto.Query, warn: false
  import Earss.Admin.Helpers
  import Earss.Admin.ControllerHelpers

  alias Earss.Admin.Views.System, as: View
  alias Earss.FeedScheduler
  alias Earss.Feeds.Feed
  alias Earss.Repo
  alias Earss.Retention

  def index(conn) do
    with_admin(conn, fn conn ->
      user = conn.assigns.admin_user
      now = utc_now()

      refresh = Application.get_env(:earss, :refresh, [])
      retention = Application.get_env(:earss, :retention, [])
      poller = Application.get_env(:earss, :poller, [])
      ret_poller = Application.get_env(:earss, :retention_poller, [])
      api = Application.get_env(:earss, :api, [])

      due = FeedScheduler.list_due_feeds(20, now)
      due_total = count_due_feeds(now)
      disabled = count_feeds(where: dynamic([f], f.is_active == false))
      errors = count_feeds(where: dynamic([f], f.error_count > 0))

      html(
        conn,
        View.page(user, flash(conn), %{
          due: due,
          due_total: due_total,
          disabled: disabled,
          errors: errors,
          refresh: refresh,
          retention: retention,
          poller: poller,
          ret_poller: ret_poller,
          api: api
        })
      )
    end)
  end

  def retention(conn) do
    with_admin(conn, fn conn ->
      mode = bp(conn, "mode") || "dry_run"
      dry_run? = mode != "run"

      result = Retention.run_all(dry_run: dry_run?)

      label = if dry_run?, do: "Dry run", else: "Retention run"

      msg =
        "#{label}: states=#{result.states.deleted}, entries=#{result.entries.deleted}, feeds=#{result.feeds.deleted}"

      conn
      |> put_flash(:ok, msg)
      |> redirect("/admin/system")
    end)
  end

  defp count_due_feeds(now) do
    from(f in Feed,
      where: f.is_active == true,
      where: is_nil(f.last_unsubscribed_at),
      where: is_nil(f.next_fetch_at) or f.next_fetch_at <= ^now,
      where: fragment("exists (select 1 from subscriptions s where s.feed_id = ?)", f.id)
    )
    |> Repo.aggregate(:count, :id)
  end

  defp count_feeds(where: dynamic) do
    from(f in Feed, where: ^dynamic)
    |> Repo.aggregate(:count, :id)
  end
end
