defmodule Earss.Admin.Controllers.Categories do
  @moduledoc false

  import Ecto.Query, warn: false
  import Earss.Admin.Helpers
  import Earss.Admin.ControllerHelpers

  alias Earss.Admin.Views.Categories, as: View
  alias Earss.Admin.Batch
  alias Earss.Feeds
  alias Earss.Reader
  alias Earss.Reader.Subscription
  alias Earss.Repo
  alias Earss.Enrichment

  def index(conn) do
    with_user(conn, fn conn ->
      user = conn.assigns.admin_user
      cats = Reader.list_categories()
      counts = subscription_counts_by_category()
      html(conn, View.index(user, flash(conn), cats, counts))
    end)
  end

  @doc "Max categories per batch delete (mirrored in the index view hint)."
  def batch_limit, do: Batch.limit()

  # Batch delete: removes the selected categories (subscriptions keep their
  # feeds and are moved to the uncategorized view).
  def batch(conn) do
    with_user(conn, fn conn ->
      ids = Batch.ids(conn)

      if ids == [] do
        conn
        |> put_flash(:err, "No categories selected")
        |> redirect("/admin/categories")
      else
        cats = Reader.list_categories() |> Enum.filter(&(&1.id in ids))

        {ok_n, fail_n, notes} =
          Batch.run(cats, fn cat -> "##{cat.id}" end, &Reader.delete_category/1)

        conn
        |> put_flash(Batch.flash_type(ok_n, fail_n), Batch.message("delete", ok_n, fail_n, notes))
        |> redirect("/admin/categories")
      end
    end)
  end

  def create(conn) do
    with_user(conn, fn conn ->
      name = bp(conn, "name")
      position = empty_to_nil(bp(conn, "position"))

      attrs = %{name: name}

      attrs =
        if position do
          Map.put(attrs, :position, parse_int(position) || 0)
        else
          attrs
        end

      case Reader.create_category(attrs) do
        {:ok, _} ->
          conn |> put_flash(:ok, "Category created") |> redirect("/admin/categories")

        {:error, reason} ->
          conn
          |> put_flash(:err, "Could not create category: #{format_error(reason)}")
          |> redirect("/admin/categories")
      end
    end)
  end

  def update(conn, id) do
    with_user(conn, fn conn ->
      user = conn.assigns.admin_user

      case owned_category(user, id) do
        nil ->
          conn |> put_flash(:err, "Not found") |> redirect("/admin/categories")

        cat ->
          name = empty_to_nil(bp(conn, "name"))
          position = empty_to_nil(bp(conn, "position"))

          attrs = %{}

          attrs =
            if name do
              Map.put(attrs, :name, name)
            else
              attrs
            end

          attrs =
            if position do
              Map.put(attrs, :position, parse_int(position) || cat.position)
            else
              attrs
            end

          case Reader.update_category(cat, attrs) do
            {:ok, _} ->
              conn |> put_flash(:ok, "Category updated") |> redirect("/admin/categories")

            {:error, reason} ->
              conn
              |> put_flash(:err, "Update failed: #{format_error(reason)}")
              |> redirect("/admin/categories")
          end
      end
    end)
  end

  def delete(conn, id) do
    with_user(conn, fn conn ->
      user = conn.assigns.admin_user

      case owned_category(user, id) do
        nil ->
          conn |> put_flash(:err, "Not found") |> redirect("/admin/categories")

        cat ->
          _ = Reader.delete_category(cat)
          conn |> put_flash(:ok, "Deleted") |> redirect("/admin/categories")
      end
    end)
  end

  # Goal 2: apply a translation target to every feed subscribed in this
  # category (shared feed-level config) and kick off async backfills.
  def apply_translation(conn, id) do
    with_user(conn, fn conn ->
      user = conn.assigns.admin_user

      case owned_category(user, id) do
        nil ->
          conn |> put_flash(:err, "Not found") |> redirect("/admin/categories")

        cat ->
          translate_to = empty_to_nil(bp(conn, "translate_to"))

          subs =
            from(s in Subscription,
              where: s.category_id == ^cat.id,
              preload: [:feed]
            )
            |> Repo.all()

          applied =
            Enum.reduce(subs, 0, fn s, acc ->
              case s.feed do
                nil ->
                  acc

                feed ->
                  case Feeds.update_feed(feed, %{translate_to: translate_to}) do
                    {:ok, updated} ->
                      # same guard as the subscription page: only clear when
                      # no per-subscription override still needs translations
                      if is_nil(translate_to) and
                           Enrichment.languages_for_feed(updated) == [] do
                        _ = Enrichment.clear_pending(updated)
                      end

                      acc + 1

                    {:error, _} ->
                      acc
                  end
              end
            end)

          if applied == 0 do
            conn
            |> put_flash(:err, "No feeds in this category")
            |> redirect("/admin/categories")
          else
            conn
            |> put_flash(:ok, "Translation applied to #{applied} feeds")
            |> redirect("/admin/categories")
          end
      end
    end)
  end

  defp subscription_counts_by_category do
    from(s in Subscription,
      where: not is_nil(s.category_id),
      group_by: s.category_id,
      select: {s.category_id, count(s.id)}
    )
    |> Repo.all()
    |> Map.new()
  end
end
