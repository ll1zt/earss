defmodule Earss.Admin.Controllers.Subscriptions do
  @moduledoc false

  import Earss.Admin.Helpers
  import Earss.Admin.ControllerHelpers

  alias Earss.Admin.Views.Subscriptions, as: View
  alias Earss.Admin.Batch
  alias Earss.Feeds
  alias Earss.Reader
  alias Earss.Enrichment

  def index(conn) do
    with_user(conn, fn conn ->
      user = conn.assigns.admin_user
      params = conn.query_params || %{}
      q = Map.get(params, "q") |> empty_to_nil()
      category_id = Map.get(params, "category_id") |> empty_to_nil()
      status = Map.get(params, "status") || "all"
      sort = Map.get(params, "sort") || "title"
      page = Map.get(params, "page") |> parse_int()

      subs = Reader.list_subscriptions(with_unread_count: true, include_hidden: true)
      cats = Reader.list_categories()
      now = utc_now()

      filtered =
        subs
        |> filter_subs_q(q)
        |> filter_subs_category(category_id)
        |> filter_subs_status(status, now)
        |> sort_subs(sort)

      {page_items, page, total_pages} = paginate(filtered, page)

      html(
        conn,
        View.index(user, flash(conn), %{
          filtered: page_items,
          subs: subs,
          q: q,
          category_id: category_id,
          status: status,
          sort: sort,
          page: page,
          total_pages: total_pages,
          total_count: length(filtered),
          cats: cats
        })
      )
    end)
  end

  def create(conn) do
    with_user(conn, fn conn ->
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

      case Reader.subscribe(attrs) do
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

  # Batch management: refresh / hide / unhide / move to category / unsubscribe
  # on the selected subscription ids (max Earss.Admin.Batch.limit()).
  def batch(conn) do
    with_user(conn, fn conn ->
      ids = Batch.ids(conn)
      action = bp(conn, "action")
      category_id = empty_to_nil(bp(conn, "category_id")) |> parse_int()

      if ids == [] do
        conn
        |> put_flash(:err, "No subscriptions selected")
        |> redirect("/admin/subscriptions")
      else
        subs =
          Reader.list_subscriptions(with_unread_count: true, include_hidden: true)
          |> Enum.filter(&(&1.id in ids))

        {ok_n, fail_n, notes} =
          Batch.run(subs, fn sub -> "##{sub.id}" end, fn sub ->
            do_batch_action(sub, action, category_id)
          end)

        conn
        |> put_flash(
          Batch.flash_type(ok_n, fail_n),
          Batch.message(action || "?", ok_n, fail_n, notes)
        )
        |> redirect(referer_or(conn, "/admin/subscriptions"))
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
          cats = Reader.list_categories()
          entries = if sub.feed, do: Feeds.list_entries(sub.feed, limit: 8), else: []

          html(conn, View.show(user, flash(conn), sub, cats, utc_now(), entries))
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
          _ = Reader.unsubscribe(sub.feed_id)
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
                original_layout: bp(conn, "feed_original_layout") || "off"
              }

              case Feeds.update_feed(feed, attrs) do
                {:ok, updated} ->
                  # disabling translation clears pending flags so originals
                  # become visible again — but only when no per-subscription
                  # override still needs translations for this feed; clearing
                  # otherwise would publish entries untranslated to readers
                  # who asked for a translation (NetNewsWire caches the first
                  # version it sees).
                  if is_nil(updated.translate_to) and
                       Enrichment.languages_for_feed(updated) == [] do
                    _ = Enrichment.clear_pending(updated)
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

  # Goal 2: re-translate a feed's paused entries (clears the pause marker;
  # the pending worker picks them up again).
  def retry_translations(conn, id) do
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
              _ = Enrichment.retry_paused(feed)

              conn
              |> put_flash(:ok, "Re-translation started for paused entries")
              |> redirect("/admin/subscriptions/#{sub.id}")
          end
      end
    end)
  end

  # Goal 2: publish a feed's pending entries without translating (clears the
  # pending flags so originals become visible).
  def publish_translations(conn, id) do
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
              _ = Enrichment.publish_pending(feed)

              conn
              |> put_flash(:ok, "Pending entries published in the original language")
              |> redirect("/admin/subscriptions/#{sub.id}")
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

  defp do_batch_action(sub, "refresh", _category_id) do
    case Feeds.refresh(sub.feed_id, force: true) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_batch_action(sub, "hide", _category_id), do: Reader.hide_subscription(sub)
  defp do_batch_action(sub, "unhide", _category_id), do: Reader.unhide_subscription(sub)

  defp do_batch_action(sub, "unsubscribe", _category_id) do
    case Reader.unsubscribe(sub.feed_id) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_batch_action(sub, "category", category_id) when is_integer(category_id) do
    case Reader.update_subscription(sub, %{category_id: category_id}) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_batch_action(_sub, "category", _category_id), do: {:error, :pick_a_category}

  defp do_batch_action(_sub, action, _category_id) when is_binary(action),
    do: {:error, {:unknown_action, action}}

  defp do_batch_action(_sub, _action, _category_id), do: {:error, :missing_action}
end
