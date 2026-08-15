defmodule Earss.Admin.Controllers.Feeds do
  @moduledoc false

  import Earss.Admin.Helpers
  import Earss.Admin.ControllerHelpers

  alias Earss.Admin.Views.Feeds, as: View
  alias Earss.Feeds
  alias Earss.Reader

  @batch_limit 50

  @doc "Max feeds per batch action (mirrored in the index view hint)."
  def batch_limit, do: @batch_limit

  def index(conn) do
    with_user(conn, fn conn ->
      user = conn.assigns.admin_user
      params = conn.query_params || %{}
      status = Map.get(params, "status") || "all"
      q = Map.get(params, "q") |> empty_to_nil()
      now = utc_now()

      subs =
        Reader.list_subscriptions(include_hidden: true)
        |> filter_subs_q(q)
        |> filter_feeds_status(status, now)

      html(
        conn,
        View.index(user, flash(conn), %{subs: subs, status: status, q: q, now: now})
      )
    end)
  end

  # Batch management: refresh / re-enable / disable on the selected feed ids
  # (max @batch_limit). Replaces the old refresh-only batch.
  def batch(conn) do
    with_user(conn, fn conn ->
      user = conn.assigns.admin_user
      ids = batch_ids(conn)
      action = bp(conn, "action") || "refresh"

      if ids == [] do
        conn
        |> put_flash(:err, "No feeds selected")
        |> redirect("/admin/feeds")
      else
        {ok_n, fail_n, notes} = run_batch(user, ids, action)

        msg =
          "Batch #{action}: #{ok_n} ok, #{fail_n} failed" <>
            if(notes == [], do: "", else: " — " <> Enum.join(Enum.take(notes, 3), "; "))

        type = if fail_n > 0 and ok_n == 0, do: :err, else: :ok

        conn
        |> put_flash(type, msg)
        |> redirect(referer_or(conn, "/admin/feeds"))
      end
    end)
  end

  def refresh(conn, id) do
    with_user(conn, fn conn ->
      user = conn.assigns.admin_user
      feed_id = parse_int(id)
      back = refresh_redirect(conn, feed_id)

      case authorized_feed(user, feed_id) do
        :ok ->
          # force: true so a previous bad parse (wrong feed_type/hash) can recover
          case Feeds.refresh(feed_id, force: true) do
            {:ok, :not_modified} ->
              conn |> put_flash(:ok, "Not modified") |> redirect(back)

            {:ok, %{upserted: n}} ->
              conn |> put_flash(:ok, "Refreshed (#{n} upserted)") |> redirect(back)

            {:error, reason} ->
              conn
              |> put_flash(:err, "Refresh failed: #{format_error(reason)}")
              |> redirect(back)
          end

        :forbidden ->
          conn |> put_flash(:err, "Not subscribed") |> redirect("/admin/feeds")
      end
    end)
  end

  def reenable(conn, id) do
    with_user(conn, fn conn ->
      user = conn.assigns.admin_user
      feed_id = parse_int(id)
      back = refresh_redirect(conn, feed_id)

      case authorized_feed(user, feed_id) do
        :ok ->
          case Feeds.get_feed(feed_id) do
            nil ->
              conn |> put_flash(:err, "Missing feed") |> redirect("/admin/feeds")

            feed ->
              _ =
                Feeds.update_feed(feed, %{
                  is_active: true,
                  error_count: 0,
                  last_error: nil,
                  next_fetch_at: DateTime.utc_now() |> DateTime.truncate(:second)
                })

              conn |> put_flash(:ok, "Feed re-enabled") |> redirect(back)
          end

        :forbidden ->
          conn |> put_flash(:err, "Not subscribed") |> redirect("/admin/feeds")
      end
    end)
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
    |> Enum.take(@batch_limit)
  end

  defp run_batch(user, ids, action) do
    Enum.reduce(ids, {0, 0, []}, fn feed_id, {ok_n, fail_n, notes} ->
      case authorized_feed(user, feed_id) do
        :ok ->
          case do_batch_action(feed_id, action) do
            :ok ->
              {ok_n + 1, fail_n, notes}

            {:error, reason} ->
              {ok_n, fail_n + 1, ["##{feed_id}: #{format_error(reason)}" | notes]}
          end

        :forbidden ->
          {ok_n, fail_n + 1, ["##{feed_id}: not allowed" | notes]}
      end
    end)
    |> then(fn {ok_n, fail_n, notes} -> {ok_n, fail_n, Enum.reverse(notes)} end)
  end

  defp do_batch_action(feed_id, "refresh") do
    case Feeds.refresh(feed_id, force: true) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_batch_action(feed_id, "reenable") do
    with %Feeds.Feed{} = feed <- Feeds.get_feed(feed_id) do
      case Feeds.update_feed(feed, %{
             is_active: true,
             error_count: 0,
             last_error: nil,
             next_fetch_at: utc_now()
           }) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      nil -> {:error, :missing_feed}
    end
  end

  defp do_batch_action(feed_id, "disable") do
    with %Feeds.Feed{} = feed <- Feeds.get_feed(feed_id) do
      case Feeds.update_feed(feed, %{is_active: false}) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      nil -> {:error, :missing_feed}
    end
  end

  defp do_batch_action(_feed_id, action) when is_binary(action),
    do: {:error, {:unknown_action, action}}

  defp do_batch_action(_feed_id, _action), do: {:error, :missing_action}

  defp refresh_redirect(conn, _feed_id) do
    case empty_to_nil(bp(conn, "return_to")) do
      path when is_binary(path) ->
        if String.starts_with?(path, "/admin"), do: path, else: "/admin/feeds"

      _ ->
        referer_or(conn, "/admin/feeds")
    end
  end
end
