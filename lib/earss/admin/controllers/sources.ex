defmodule Earss.Admin.Controllers.Sources do
  @moduledoc false

  import Earss.Admin.Helpers
  import Earss.Admin.ControllerHelpers

  alias Earss.Admin.Views.Sources, as: View
  alias Earss.Reader
  alias Earss.Source.Registry

  def index(conn) do
    with_user(conn, fn conn ->
      user = conn.assigns.admin_user
      cats = Reader.list_categories(user)
      adapters = Registry.list_adapters()
      routes = Registry.list_routes()

      html(
        conn,
        View.index(user, flash(conn), %{
          adapters: adapters,
          routes: routes,
          cats: cats
        })
      )
    end)
  end

  def subscribe(conn) do
    with_user(conn, fn conn ->
      user = conn.assigns.admin_user
      refresh? = bp(conn, "refresh") != "false"
      cat = empty_to_nil(bp(conn, "category_id"))

      link =
        case empty_to_nil(bp(conn, "link")) do
          nil -> build_link_from_route(conn)
          raw -> String.trim(raw)
        end

      cond do
        not is_binary(link) or link == "" ->
          conn
          |> put_flash(:err, "Source URL or route parameters required")
          |> redirect("/admin/sources")

        true ->
          attrs = %{
            "link" => link,
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
              |> put_flash(:ok, "Subscribed to #{sub.feed.link}")
              |> redirect("/admin/subscriptions/#{sub.id}")

            {:error, reason} ->
              conn
              |> put_flash(:err, "Subscribe failed: #{format_error(reason)}")
              |> redirect("/admin/sources")
          end
      end
    end)
  end

  defp build_link_from_route(conn) do
    adapter_id = empty_to_nil(bp(conn, "adapter_id"))
    path_tmpl = empty_to_nil(bp(conn, "path"))

    if adapter_id && path_tmpl do
      path = expand_path_template(path_tmpl, conn)
      "earss://#{adapter_id}/#{String.trim_leading(path, "/")}"
    else
      nil
    end
  end

  defp expand_path_template(template, conn) do
    Regex.replace(~r/:([A-Za-z_][A-Za-z0-9_]*)/, template, fn _full, name ->
      val =
        empty_to_nil(bp(conn, "param_#{name}")) ||
          empty_to_nil(bp(conn, name))

      (val || "")
      |> String.trim()
      |> String.trim_leading("@")
    end)
  end
end
