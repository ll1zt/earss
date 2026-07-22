defmodule Earss.Admin.Router do
  @moduledoc """
  Server-rendered admin UI at `/admin`.
  """

  use Plug.Router

  import Ecto.Query, warn: false

  alias Earss.Admin.{Auth, HTML}
  alias Earss.Reader
  alias Earss.Feeds
  alias Earss.Repo
  alias Earss.Reader.Subscription

  # Parent router already ran parsers + session.
  plug(:match)
  plug(:fetch_flash_assign)
  plug(Auth)
  plug(:dispatch)

  # --- public ---

  get "/login" do
    if conn.assigns.admin_user do
      redirect(conn, "/admin")
    else
      html(conn, HTML.login_page(flash(conn)))
    end
  end

  post "/login" do
    username = bp(conn, "username")
    password = bp(conn, "password")

    case Reader.authenticate_user(username || "", password || "") do
      {:ok, user} ->
        conn
        |> Auth.login(user)
        |> put_flash(:ok, "Signed in as #{user.username}")
        |> redirect("/admin")

      {:error, _} ->
        html(conn, HTML.login_page(nil, "Invalid username or password"))
    end
  end

  post "/logout" do
    conn
    |> Auth.logout()
    |> redirect("/admin/login")
  end

  # --- authenticated ---

  get "/" do
    conn = Auth.require_user(conn, [])
    if conn.halted, do: conn, else: dashboard(conn)
  end

  get "/subscriptions" do
    with_user(conn, &subscriptions_index/1)
  end

  post "/subscriptions" do
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
        {:ok, _} ->
          conn |> put_flash(:ok, "Subscribed") |> redirect("/admin/subscriptions")

        {:error, %Ecto.Changeset{} = cs} ->
          conn
          |> put_flash(:err, "Subscribe failed: #{inspect(cs.errors)}")
          |> redirect("/admin/subscriptions")

        {:error, reason} ->
          conn
          |> put_flash(:err, "Subscribe failed: #{inspect(reason)}")
          |> redirect("/admin/subscriptions")
      end
    end)
  end

  post "/subscriptions/:id/unsubscribe" do
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

  post "/subscriptions/:id/hide" do
    with_user(conn, fn conn ->
      user = conn.assigns.admin_user

      case owned_sub(user, id) do
        nil ->
          conn |> put_flash(:err, "Not found") |> redirect("/admin/subscriptions")

        sub ->
          _ = Reader.hide_subscription(sub)
          conn |> put_flash(:ok, "Hidden") |> redirect("/admin/subscriptions")
      end
    end)
  end

  post "/subscriptions/:id/unhide" do
    with_user(conn, fn conn ->
      user = conn.assigns.admin_user

      case owned_sub(user, id) do
        nil ->
          conn |> put_flash(:err, "Not found") |> redirect("/admin/subscriptions")

        sub ->
          _ = Reader.unhide_subscription(sub)
          conn |> put_flash(:ok, "Unhidden") |> redirect("/admin/subscriptions")
      end
    end)
  end

  post "/subscriptions/:id/category" do
    with_user(conn, fn conn ->
      user = conn.assigns.admin_user
      cat = empty_to_nil(bp(conn, "category_id"))

      case owned_sub(user, id) do
        nil ->
          conn |> put_flash(:err, "Not found") |> redirect("/admin/subscriptions")

        sub ->
          attrs =
            if cat do
              %{category_id: String.to_integer(cat)}
            else
              %{category_id: nil}
            end

          case Reader.update_subscription(sub, attrs) do
            {:ok, _} ->
              conn |> put_flash(:ok, "Category updated") |> redirect("/admin/subscriptions")

            {:error, _} ->
              conn |> put_flash(:err, "Update failed") |> redirect("/admin/subscriptions")
          end
      end
    end)
  end

  get "/categories" do
    with_user(conn, &categories_index/1)
  end

  post "/categories" do
    with_user(conn, fn conn ->
      user = conn.assigns.admin_user
      name = bp(conn, "name")

      case Reader.create_category(user, %{name: name}) do
        {:ok, _} ->
          conn |> put_flash(:ok, "Category created") |> redirect("/admin/categories")

        {:error, _} ->
          conn |> put_flash(:err, "Could not create category") |> redirect("/admin/categories")
      end
    end)
  end

  post "/categories/:id/delete" do
    with_user(conn, fn conn ->
      user = conn.assigns.admin_user

      case Reader.get_category(String.to_integer(id)) do
        %{user_id: uid} = cat when uid == user.id ->
          _ = Reader.delete_category(cat)
          conn |> put_flash(:ok, "Deleted") |> redirect("/admin/categories")

        _ ->
          conn |> put_flash(:err, "Not found") |> redirect("/admin/categories")
      end
    end)
  end

  get "/feeds" do
    with_user(conn, &feeds_index/1)
  end

  post "/feeds/:id/refresh" do
    with_user(conn, fn conn ->
      user = conn.assigns.admin_user
      feed_id = String.to_integer(id)

      case Reader.get_subscription(user, feed_id) do
        nil ->
          conn |> put_flash(:err, "Not subscribed") |> redirect("/admin/feeds")

        _ ->
          case Feeds.refresh(feed_id) do
            {:ok, :not_modified} ->
              conn |> put_flash(:ok, "Not modified") |> redirect("/admin/feeds")

            {:ok, %{upserted: n}} ->
              conn |> put_flash(:ok, "Refreshed (#{n} upserted)") |> redirect("/admin/feeds")

            {:error, reason} ->
              conn
              |> put_flash(:err, "Refresh failed: #{inspect(reason)}")
              |> redirect("/admin/feeds")
          end
      end
    end)
  end

  post "/feeds/:id/reenable" do
    with_user(conn, fn conn ->
      user = conn.assigns.admin_user
      feed_id = String.to_integer(id)

      case Reader.get_subscription(user, feed_id) do
        nil ->
          conn |> put_flash(:err, "Not subscribed") |> redirect("/admin/feeds")

        _ ->
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

              conn |> put_flash(:ok, "Feed re-enabled") |> redirect("/admin/feeds")
          end
      end
    end)
  end

  get "/opml" do
    with_user(conn, &opml_page/1)
  end

  get "/opml/export" do
    with_user(conn, fn conn ->
      user = conn.assigns.admin_user

      case Reader.export_opml(user) do
        {:ok, xml} ->
          conn
          |> put_resp_content_type("text/x-opml+xml")
          |> put_resp_header(
            "content-disposition",
            "attachment; filename=\"earss-#{user.username}.opml\""
          )
          |> send_resp(200, xml)
      end
    end)
  end

  post "/opml/import" do
    with_user(conn, fn conn ->
      user = conn.assigns.admin_user
      xml = bp(conn, "opml") || ""

      case Reader.import_opml(user, xml, refresh: false) do
        {:ok, stats} ->
          conn
          |> put_flash(
            :ok,
            "Import done: #{stats.imported} imported, #{stats.skipped} skipped, #{stats.errors} errors"
          )
          |> redirect("/admin/opml")

        {:error, reason} ->
          conn
          |> put_flash(:err, "Import failed: #{inspect(reason)}")
          |> redirect("/admin/opml")
      end
    end)
  end

  get "/settings" do
    with_user(conn, &settings_page/1)
  end

  post "/settings/password" do
    with_user(conn, fn conn ->
      user = conn.assigns.admin_user
      pass = bp(conn, "password") || ""
      pass2 = bp(conn, "password_confirm") || ""

      cond do
        String.length(pass) < 4 ->
          conn |> put_flash(:err, "Password too short") |> redirect("/admin/settings")

        pass != pass2 ->
          conn |> put_flash(:err, "Passwords do not match") |> redirect("/admin/settings")

        true ->
          case Reader.set_password(user, pass) do
            {:ok, _} ->
              conn
              |> put_flash(:ok, "Password updated (Fever key recomputed from new password)")
              |> redirect("/admin/settings")

            {:error, _} ->
              conn |> put_flash(:err, "Update failed") |> redirect("/admin/settings")
          end
      end
    end)
  end

  post "/settings/fever" do
    with_user(conn, fn conn ->
      user = conn.assigns.admin_user
      secret = bp(conn, "fever_secret") || ""

      if String.trim(secret) == "" do
        conn |> put_flash(:err, "Secret required") |> redirect("/admin/settings")
      else
        case Reader.set_fever_password(user, secret) do
          {:ok, _} ->
            conn
            |> put_flash(
              :ok,
              "Fever secret set. In NetNewsWire use username + this secret as password."
            )
            |> redirect("/admin/settings")

          {:error, _} ->
            conn |> put_flash(:err, "Failed") |> redirect("/admin/settings")
        end
      end
    end)
  end

  match _ do
    if conn.assigns[:admin_user] do
      conn |> put_flash(:err, "Not found") |> redirect("/admin")
    else
      redirect(conn, "/admin/login")
    end
  end

  ## Pages

  defp dashboard(conn) do
    user = conn.assigns.admin_user
    subs = Reader.list_subscriptions(user, with_unread_count: true, include_hidden: true)
    unread = Enum.reduce(subs, 0, fn s, acc -> acc + (s.unread_count || 0) end)
    cats = Reader.list_categories(user)

    failed =
      Enum.count(subs, fn s ->
        s.feed && (s.feed.error_count > 0 or s.feed.is_active == false)
      end)

    host = conn.host
    port = conn.port

    fever_url =
      if port in [80, 443] do
        "#{conn.scheme}://#{host}/fever/"
      else
        "#{conn.scheme}://#{host}:#{port}/fever/"
      end

    inner = """
    <div class="card row">
      <div class="stat"><div class="muted">Subscriptions</div><div class="n">#{length(subs)}</div></div>
      <div class="stat"><div class="muted">Unread</div><div class="n">#{unread}</div></div>
      <div class="stat"><div class="muted">Categories</div><div class="n">#{length(cats)}</div></div>
      <div class="stat"><div class="muted">Problem feeds</div><div class="n">#{failed}</div></div>
    </div>
    <div class="card">
      <h2>NetNewsWire (Fever)</h2>
      <p>Server URL: <code>#{HTML.h(fever_url)}</code></p>
      <p class="muted">Username: <code>#{HTML.h(user.username)}</code> — password is your login password (or Fever-only secret from Settings).</p>
      <p class="muted">Reading happens in NNW; this admin is for sources and account only.</p>
    </div>
    """

    html(conn, HTML.shell(user, flash(conn), "Dashboard", inner))
  end

  defp subscriptions_index(conn) do
    user = conn.assigns.admin_user
    subs = Reader.list_subscriptions(user, with_unread_count: true, include_hidden: true)
    cats = Reader.list_categories(user)

    cat_opts =
      ["<option value=\"\">— none —</option>"] ++
        Enum.map(cats, fn c ->
          ~s(<option value="#{c.id}">#{HTML.h(c.name)}</option>)
        end)

    cat_opts = Enum.join(cat_opts, "")

    rows =
      Enum.map(subs, fn s ->
        title = s.custom_title || (s.feed && s.feed.title) || s.feed.link
        cat_name = (s.category && s.category.name) || "—"
        hidden = if s.is_hidden, do: "yes", else: "no"
        unread = s.unread_count || 0

        hide_btn =
          if s.is_hidden do
            ~s(<form method="post" action="/admin/subscriptions/#{s.id}/unhide"><button type="submit" class="secondary">Unhide</button></form>)
          else
            ~s(<form method="post" action="/admin/subscriptions/#{s.id}/hide"><button type="submit" class="secondary">Hide</button></form>)
          end

        """
        <tr>
          <td>#{HTML.h(title)}<div class="muted">#{HTML.h(s.feed.link)}</div></td>
          <td>#{unread}</td>
          <td>#{HTML.h(cat_name)}</td>
          <td>#{hidden}</td>
          <td class="actions">
            <form method="post" action="/admin/subscriptions/#{s.id}/category">
              <select name="category_id" onchange="this.form.submit()">#{cat_opts}</select>
            </form>
            #{hide_btn}
            <form method="post" action="/admin/subscriptions/#{s.id}/unsubscribe" onsubmit="return confirm('Unsubscribe?')">
              <button type="submit" class="danger">Unsubscribe</button>
            </form>
          </td>
        </tr>
        """
      end)
      |> Enum.join("\n")

    inner = """
    <div class="card">
      <h2>Add subscription</h2>
      <form method="post" action="/admin/subscriptions">
        <label>Feed URL</label>
        <input name="link" type="url" required placeholder="https://example.com/feed.xml"/>
        <label>Title (optional)</label>
        <input name="title" placeholder="Display title"/>
        <label>Category</label>
        <select name="category_id">#{cat_opts}</select>
        <label><input type="checkbox" name="refresh" value="true" checked/> Fetch now</label>
        <div><button type="submit">Subscribe</button></div>
      </form>
    </div>
    <div class="card">
      <table>
        <thead><tr><th>Feed</th><th>Unread</th><th>Category</th><th>Hidden</th><th></th></tr></thead>
        <tbody>#{rows}</tbody>
      </table>
    </div>
    """

    html(conn, HTML.shell(user, flash(conn), "Subscriptions", inner))
  end

  defp categories_index(conn) do
    user = conn.assigns.admin_user
    cats = Reader.list_categories(user)

    rows =
      Enum.map(cats, fn c ->
        """
        <tr>
          <td>#{HTML.h(c.name)}</td>
          <td>#{c.position}</td>
          <td class="actions">
            <form method="post" action="/admin/categories/#{c.id}/delete" onsubmit="return confirm('Delete category?')">
              <button type="submit" class="danger">Delete</button>
            </form>
          </td>
        </tr>
        """
      end)
      |> Enum.join("\n")

    inner = """
    <div class="card">
      <form method="post" action="/admin/categories">
        <label>Name</label>
        <input name="name" required/>
        <button type="submit">Create</button>
      </form>
    </div>
    <div class="card">
      <table>
        <thead><tr><th>Name</th><th>Position</th><th></th></tr></thead>
        <tbody>#{rows}</tbody>
      </table>
    </div>
    """

    html(conn, HTML.shell(user, flash(conn), "Categories", inner))
  end

  defp feeds_index(conn) do
    user = conn.assigns.admin_user
    subs = Reader.list_subscriptions(user, include_hidden: true)

    rows =
      Enum.map(subs, fn s ->
        f = s.feed
        title = s.custom_title || f.title || f.link
        status = if f.is_active, do: "active", else: "disabled"
        err = f.last_error || ""
        last = f.last_fetched_at && Calendar.strftime(f.last_fetched_at, "%Y-%m-%d %H:%M")

        """
        <tr>
          <td>#{HTML.h(title)}<div class="muted">#{HTML.h(f.link)}</div>
            #{if err != "", do: ~s(<div class="err-text">#{HTML.h(err)}</div>), else: ""}
          </td>
          <td>#{status}</td>
          <td>#{f.error_count}</td>
          <td class="muted">#{HTML.h(last || "—")}</td>
          <td class="actions">
            <form method="post" action="/admin/feeds/#{f.id}/refresh"><button type="submit">Refresh</button></form>
            <form method="post" action="/admin/feeds/#{f.id}/reenable"><button type="submit" class="secondary">Re-enable</button></form>
          </td>
        </tr>
        """
      end)
      |> Enum.join("\n")

    inner = """
    <div class="card">
      <p class="muted">Feeds you subscribe to. Refresh runs a single fetch; re-enable clears error circuit-breaker.</p>
      <table>
        <thead><tr><th>Feed</th><th>Status</th><th>Errors</th><th>Last fetch</th><th></th></tr></thead>
        <tbody>#{rows}</tbody>
      </table>
    </div>
    """

    html(conn, HTML.shell(user, flash(conn), "Feeds", inner))
  end

  defp opml_page(conn) do
    user = conn.assigns.admin_user

    inner = """
    <div class="card">
      <h2>Export</h2>
      <p><a class="btn" href="/admin/opml/export">Download OPML</a></p>
    </div>
    <div class="card">
      <h2>Import</h2>
      <p class="muted">Paste OPML XML. Feeds are queued for the poller (no immediate refresh).</p>
      <form method="post" action="/admin/opml/import">
        <textarea name="opml" required placeholder="&lt;opml ...&gt;"></textarea>
        <div><button type="submit">Import</button></div>
      </form>
    </div>
    """

    html(conn, HTML.shell(user, flash(conn), "OPML", inner))
  end

  defp settings_page(conn) do
    user = conn.assigns.admin_user
    key_preview = user.fever_api_key || "(not set — set password or Fever secret)"

    key_short =
      if is_binary(user.fever_api_key) and byte_size(user.fever_api_key) > 12 do
        String.slice(user.fever_api_key, 0, 8) <> "…" <> String.slice(user.fever_api_key, -4, 4)
      else
        key_preview
      end

    host = conn.host
    port = conn.port

    fever_url =
      if port in [80, 443] do
        "#{conn.scheme}://#{host}/fever/"
      else
        "#{conn.scheme}://#{host}:#{port}/fever/"
      end

    inner = """
    <div class="card">
      <h2>Fever / NetNewsWire</h2>
      <p>URL: <code>#{HTML.h(fever_url)}</code></p>
      <p>Username: <code>#{HTML.h(user.username)}</code></p>
      <p class="muted">Stored api_key fingerprint: <code>#{HTML.h(key_short)}</code></p>
      <form method="post" action="/admin/settings/fever">
        <label>Fever-only password/secret (does not change login password)</label>
        <input name="fever_secret" type="password" autocomplete="new-password"/>
        <button type="submit">Set Fever secret</button>
      </form>
    </div>
    <div class="card">
      <h2>Login password</h2>
      <p class="muted">Also recomputes Fever api_key from username:new_password.</p>
      <form method="post" action="/admin/settings/password">
        <label>New password</label>
        <input name="password" type="password" autocomplete="new-password" required/>
        <label>Confirm</label>
        <input name="password_confirm" type="password" autocomplete="new-password" required/>
        <button type="submit">Update password</button>
      </form>
    </div>
    """

    html(conn, HTML.shell(user, flash(conn), "Settings", inner))
  end

  ## helpers

  defp with_user(conn, fun) do
    conn = Auth.require_user(conn, [])
    if conn.halted, do: conn, else: fun.(conn)
  end

  defp owned_sub(user, id) do
    id = String.to_integer(id)

    case Repo.get(Subscription, id) do
      %Subscription{user_id: uid} = sub when uid == user.id ->
        Repo.preload(sub, [:feed, :category])

      _ ->
        nil
    end
  end

  defp bp(conn, key) do
    case conn.body_params do
      %{} = m -> Map.get(m, key)
      _ -> nil
    end
  end

  defp empty_to_nil(nil), do: nil
  defp empty_to_nil(""), do: nil
  defp empty_to_nil(v), do: v

  defp html(conn, body) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, body)
  end

  defp redirect(conn, path) do
    conn
    |> put_resp_header("location", path)
    |> send_resp(302, "")
  end

  defp flash(conn), do: conn.assigns[:flash]

  defp put_flash(conn, type, msg) do
    # Persist across redirect via session
    put_session(conn, :admin_flash, {type, msg})
  end

  defp fetch_flash_assign(conn, _opts) do
    {flash, conn} =
      case get_session(conn, :admin_flash) do
        nil ->
          {nil, conn}

        f ->
          {f, delete_session(conn, :admin_flash)}
      end

    assign(conn, :flash, flash)
  end
end
