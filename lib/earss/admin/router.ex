defmodule Earss.Admin.Router do
  @moduledoc """
  Server-rendered admin UI at `/admin` (admin-v0.3, CRT / Paper themes).

  Thin dispatch layer: request handling lives in `Earss.Admin.Controllers.*`,
  HTML in `Earss.Admin.Views.*`, shared utilities in `Helpers` / `ControllerHelpers`.
  """

  use Plug.Router

  import Plug.Conn
  import Earss.Admin.Helpers, except: [fetch_flash_assign: 2]

  alias Earss.Admin.Auth
  alias Earss.Admin.Theme

  alias Earss.Admin.Controllers.{
    Categories,
    Dashboard,
    Export,
    Feeds,
    OPML,
    Session,
    Settings,
    Sources,
    Subscriptions,
    System,
    Translate
  }

  # Parent router already ran parsers + session.
  plug(:match)
  plug(:fetch_flash_assign)
  plug(:fetch_admin_theme)
  plug(:protect_from_forgery)
  plug(Auth)
  plug(:dispatch)

  defp fetch_admin_theme(conn, _opts), do: Theme.fetch(conn)

  # Plug macros resolve function plugs on this module.
  defp fetch_flash_assign(conn, opts), do: Earss.Admin.Helpers.fetch_flash_assign(conn, opts)

  # Wrap Plug.CSRFProtection so invalid tokens redirect instead of raising
  # out of the request (ErrorHandler always re-raises after sending).
  defp protect_from_forgery(conn, _opts) do
    Plug.CSRFProtection.call(conn, Plug.CSRFProtection.init([]))
  rescue
    Plug.CSRFProtection.InvalidCSRFTokenError ->
      csrf_reject(conn)

    e in Plug.Conn.WrapperError ->
      case e do
        %{reason: %Plug.CSRFProtection.InvalidCSRFTokenError{}, conn: c} ->
          csrf_reject(c || conn)

        _ ->
          reraise e, __STACKTRACE__
      end
  end

  defp csrf_reject(conn) do
    dest =
      case get_req_header(conn, "referer") do
        [ref] ->
          uri = URI.parse(ref)

          if is_binary(uri.path) and String.starts_with?(uri.path, "/admin") do
            uri.path
          else
            "/admin"
          end

        _ ->
          "/admin"
      end

    dest =
      if dest == "/admin/login" or conn.path_info == ["login"] do
        "/admin/login"
      else
        dest
      end

    conn
    |> put_session(
      :admin_flash,
      {:err, "Invalid or missing CSRF token. Reload the page and try again."}
    )
    |> put_resp_header("location", dest)
    |> send_resp(302, "")
    |> halt()
  end

  # --- public ---

  get "/login" do
    Session.new(conn)
  end

  post "/login" do
    Session.create(conn)
  end

  post "/logout" do
    Session.delete(conn)
  end

  # Theme switch (session); allowed logged-out so login page can switch too.
  post "/theme" do
    theme = bp(conn, "theme")
    back = referer_or(conn, "/admin")

    back =
      if is_binary(back) and String.starts_with?(back, "/admin") do
        back
      else
        "/admin"
      end

    conn
    |> Theme.put(theme)
    |> put_flash(:ok, "Theme: #{Theme.label(Theme.normalize(theme))}")
    |> redirect(back)
  end

  # --- authenticated ---

  get "/" do
    Dashboard.index(conn)
  end

  get "/subscriptions" do
    Subscriptions.index(conn)
  end

  post "/subscriptions" do
    Subscriptions.create(conn)
  end

  get "/subscriptions/:id" do
    Subscriptions.show(conn, id)
  end

  post "/subscriptions/:id" do
    Subscriptions.update(conn, id)
  end

  post "/subscriptions/:id/unsubscribe" do
    Subscriptions.unsubscribe(conn, id)
  end

  post "/subscriptions/:id/hide" do
    Subscriptions.hide(conn, id)
  end

  post "/subscriptions/:id/unhide" do
    Subscriptions.unhide(conn, id)
  end

  post "/subscriptions/:id/category" do
    Subscriptions.update_category(conn, id)
  end

  post "/subscriptions/:id/translation" do
    Subscriptions.update_translation(conn, id)
  end

  post "/subscriptions/:id/feed_translation" do
    Subscriptions.update_feed_translation(conn, id)
  end

  post "/subscriptions/:id/backfill_translations" do
    Subscriptions.backfill_translations(conn, id)
  end

  get "/sources" do
    Sources.index(conn)
  end

  post "/sources/subscribe" do
    Sources.subscribe(conn)
  end

  get "/categories" do
    Categories.index(conn)
  end

  post "/categories" do
    Categories.create(conn)
  end

  post "/categories/:id" do
    Categories.update(conn, id)
  end

  post "/categories/:id/delete" do
    Categories.delete(conn, id)
  end

  post "/categories/:id/translation" do
    Categories.apply_translation(conn, id)
  end

  get "/feeds" do
    Feeds.index(conn)
  end

  post "/feeds/refresh_batch" do
    Feeds.refresh_batch(conn)
  end

  post "/feeds/:id/refresh" do
    Feeds.refresh(conn, id)
  end

  post "/feeds/:id/reenable" do
    Feeds.reenable(conn, id)
  end

  get "/system" do
    System.index(conn)
  end

  post "/system/retention" do
    System.retention(conn)
  end

  get "/opml" do
    OPML.index(conn)
  end

  get "/opml/export" do
    OPML.export(conn)
  end

  post "/opml/import" do
    OPML.import(conn)
  end

  get "/export" do
    Export.index(conn)
  end

  get "/export/starred" do
    Export.starred(conn)
  end

  get "/export/all" do
    Export.all(conn)
  end

  get "/translate" do
    Translate.index(conn)
  end

  get "/settings" do
    Settings.index(conn)
  end

  post "/settings/password" do
    Settings.update_password(conn)
  end

  post "/settings/fever" do
    Settings.update_fever(conn)
  end

  match _ do
    if conn.assigns[:admin_user] do
      conn |> put_flash(:err, "Not found") |> redirect("/admin")
    else
      redirect(conn, "/admin/login")
    end
  end
end
