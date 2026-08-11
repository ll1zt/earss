defmodule Earss.Admin.Controllers.Subscriptions do
  @moduledoc false

  import Earss.Admin.Helpers
  import Earss.Admin.ControllerHelpers

  alias Earss.Admin.Views.Subscriptions, as: View
  alias Earss.Feeds
  alias Earss.Reader
  alias Earss.Translate

  def index(conn) do
    with_user(conn, fn conn ->
      user = conn.assigns.admin_user
      params = conn.query_params || %{}
      q = Map.get(params, "q") |> empty_to_nil()
      category_id = Map.get(params, "category_id") |> empty_to_nil()
      status = Map.get(params, "status") || "all"
      sort = Map.get(params, "sort") || "title"

      subs = Reader.list_subscriptions(user, with_unread_count: true, include_hidden: true)
      cats = Reader.list_categories(user)
      now = utc_now()

      filtered =
        subs
        |> filter_subs_q(q)
        |> filter_subs_category(category_id)
        |> filter_subs_status(status, now)
        |> sort_subs(sort)

      html(
        conn,
        View.index(user, flash(conn), %{
          filtered: filtered,
          subs: subs,
          q: q,
          category_id: category_id,
          status: status,
          sort: sort,
          cats: cats
        })
      )
    end)
  end

  def create(conn) do
    with_user(conn, fn conn ->
      user = conn.assigns.admin_user
      link = bp(conn, "link")
      title = empty_to_nil(bp(conn, "title"))
      cat = empty_to_nil(bp(conn, "category_id"))
      refresh? = bp(conn, "refresh") != "false"

      attrs = %{
        "link" => link,
        "title" => title,
        "refresh" => refresh?
      }

      attrs =
        if cat do
          Map.put(attrs, "category_id", cat)
        else
          attrs
        end

      case Reader.subscribe(user, attrs) do
        {:ok, sub} ->
          conn
          |> put_flash(:ok, "Subscribed")
          |> redirect("/admin/subscriptions/#{sub.id}")

        {:error, reason} ->
          conn
          |> put_flash(:err, "Subscribe failed: #{format_error(reason)}")
          |> redirect("/admin/subscriptions")
      end
    end)
  end

  def show(conn, id) do
    with_user(conn, fn conn ->
      user = conn.assigns.admin_user

      case owned_sub(user, id) do
        nil ->
          conn |> put_flash(:err, "Not found") |> redirect("/admin/subscriptions")

        sub ->
          cats = Reader.list_categories(user)

          html(conn, View.show(user, flash(conn), sub, cats, utc_now()))
      end
    end)
  end

  def update(conn, id) do
    with_user(conn, fn conn ->
      user = conn.assigns.admin_user

      case owned_sub(user, id) do
        nil ->
          conn |> put_flash(:err, "Not found") |> redirect("/admin/subscriptions")

        sub ->
          attrs = subscription_form_attrs(conn)

          case Reader.update_subscription(sub, attrs) do
            {:ok, updated} ->
              conn
              |> put_flash(:ok, "Subscription updated")
              |> redirect("/admin/subscriptions/#{updated.id}")

            {:error, reason} ->
              conn
              |> put_flash(:err, "Update failed: #{format_error(reason)}")
              |> redirect("/admin/subscriptions/#{sub.id}")
          end
      end
    end)
  end

  def unsubscribe(conn, id) do
    with_user(conn, fn conn ->
      user = conn.assigns.admin_user

      case owned_sub(user, id) do
        nil ->
          conn |> put_flash(:err, "Not found") |> redirect("/admin/subscriptions")

        sub ->
          _ = Reader.unsubscribe(user, sub.feed_id)
          conn |> put_flash(:ok, "Unsubscribed") |> redirect("/admin/subscriptions")
      end
    end)
  end

  def hide(conn, id) do
    with_user(conn, fn conn ->
      user = conn.assigns.admin_user

      case owned_sub(user, id) do
        nil ->
          conn |> put_flash(:err, "Not found") |> redirect("/admin/subscriptions")

        sub ->
          _ = Reader.hide_subscription(sub)
          back = referer_or(conn, "/admin/subscriptions/#{sub.id}")
          conn |> put_flash(:ok, "Hidden") |> redirect(back)
      end
    end)
  end

  def unhide(conn, id) do
    with_user(conn, fn conn ->
      user = conn.assigns.admin_user

      case owned_sub(user, id) do
        nil ->
          conn |> put_flash(:err, "Not found") |> redirect("/admin/subscriptions")

        sub ->
          _ = Reader.unhide_subscription(sub)
          back = referer_or(conn, "/admin/subscriptions/#{sub.id}")
          conn |> put_flash(:ok, "Unhidden") |> redirect(back)
      end
    end)
  end

  def update_category(conn, id) do
    with_user(conn, fn conn ->
      user = conn.assigns.admin_user
      cat = empty_to_nil(bp(conn, "category_id"))

      case owned_sub(user, id) do
        nil ->
          conn |> put_flash(:err, "Not found") |> redirect("/admin/subscriptions")

        sub ->
          attrs =
            if cat do
              %{category_id: parse_int(cat)}
            else
              %{category_id: nil}
            end

          case Reader.update_subscription(sub, attrs) do
            {:ok, _} ->
              conn |> put_flash(:ok, "Category updated") |> redirect("/admin/subscriptions")

            {:error, reason} ->
              conn
              |> put_flash(:err, "Update failed: #{format_error(reason)}")
              |> redirect("/admin/subscriptions")
          end
      end
    end)
  end

  # Goal 2: per-subscription translation override (this user only). Enabling
  # triggers an async backfill so existing entries get translated too.
  def update_translation(conn, id) do
    with_user(conn, fn conn ->
      user = conn.assigns.admin_user

      case owned_sub(user, id) do
        nil ->
          conn |> put_flash(:err, "Not found") |> redirect("/admin/subscriptions")

        sub ->
          attrs = %{
            translate_to: empty_to_nil(bp(conn, "translate_to")),
            return_original: bp(conn, "return_original") not in [nil, "", "false", "0"]
          }

          case Reader.update_subscription(sub, attrs) do
            {:ok, updated} ->
              if updated.translate_to do
                _ = Translate.backfill_async(updated.feed, langs: [updated.translate_to])
              end

              conn
              |> put_flash(:ok, "Subscription translation updated")
              |> redirect("/admin/subscriptions/#{updated.id}")

            {:error, reason} ->
              conn
              |> put_flash(:err, "Update failed: #{format_error(reason)}")
              |> redirect("/admin/subscriptions/#{sub.id}")
          end
      end
    end)
  end

  # Goal 2: feed-level translation configuration (shared content fact).
  def update_feed_translation(conn, id) do
    with_user(conn, fn conn ->
      user = conn.assigns.admin_user

      case owned_sub(user, id) do
        nil ->
          conn |> put_flash(:err, "Not found") |> redirect("/admin/subscriptions")

        sub ->
          case sub.feed do
            nil ->
              conn
              |> put_flash(:err, "Feed missing")
              |> redirect("/admin/subscriptions/#{sub.id}")

            feed ->
              attrs = %{
                translate_to: empty_to_nil(bp(conn, "feed_translate_to")),
                translate_from: empty_to_nil(bp(conn, "feed_translate_from")),
                return_original: bp(conn, "feed_return_original") not in [nil, "", "false", "0"]
              }

              case Feeds.update_feed(feed, attrs) do
                {:ok, updated} ->
                  if updated.translate_to do
                    _ = Translate.backfill_async(updated, langs: [updated.translate_to])
                  end

                  conn
                  |> put_flash(:ok, "Feed translation updated")
                  |> redirect("/admin/subscriptions/#{sub.id}")

                {:error, reason} ->
                  conn
                  |> put_flash(:err, "Update failed: #{format_error(reason)}")
                  |> redirect("/admin/subscriptions/#{sub.id}")
              end
          end
      end
    end)
  end

  # Goal 2: synchronous backfill triggered from the admin UI button.
  # Goal 2: backfill triggered from the admin UI button. Runs asynchronously
  # (provider calls take tens of seconds per entry; the HTTP request must not
  # hang). Progress/errors are visible via the feed's translate_error_count and
  # server logs; an idempotent re-run only fills the gaps.
  def backfill_translations(conn, id) do
    with_user(conn, fn conn ->
      user = conn.assigns.admin_user

      case owned_sub(user, id) do
        nil ->
          conn |> put_flash(:err, "Not found") |> redirect("/admin/subscriptions")

        sub ->
          case sub.feed do
            nil ->
              conn
              |> put_flash(:err, "Feed missing")
              |> redirect("/admin/subscriptions/#{sub.id}")

            feed ->
              cond do
                is_nil(Translate.translator()) ->
                  conn
                  |> put_flash(:err, "No translation plugin loaded")
                  |> redirect("/admin/subscriptions/#{sub.id}")

                Translate.languages_for_feed(feed) == [] ->
                  conn
                  |> put_flash(:err, "No translation language configured")
                  |> redirect("/admin/subscriptions/#{sub.id}")

                true ->
                  _ = Translate.backfill_async(feed)

                  conn
                  |> put_flash(:ok, "Backfill started in the background")
                  |> redirect("/admin/subscriptions/#{sub.id}")
              end
          end
      end
    end)
  end

  defp subscription_form_attrs(conn) do
    custom_title = empty_to_nil(bp(conn, "custom_title"))
    interval_raw = empty_to_nil(bp(conn, "custom_refresh_interval"))
    cat = empty_to_nil(bp(conn, "category_id"))
    hidden? = bp(conn, "is_hidden") in ["true", "1", "on"]

    interval =
      case interval_raw do
        nil -> nil
        raw -> parse_int(raw)
      end

    %{
      custom_title: custom_title,
      custom_refresh_interval: interval,
      category_id: if(cat, do: parse_int(cat), else: nil),
      is_hidden: hidden?
    }
  end
end
