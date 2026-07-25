defmodule Earss.Admin.Router do
  @moduledoc """
  Server-rendered admin UI at `/admin` (admin-v0.2).
  """

  use Plug.Router

  import Ecto.Query, warn: false
  import Plug.Conn

  alias Earss.Admin.{Auth, HTML}
  alias Earss.Reader
  alias Earss.Feeds
  alias Earss.FeedScheduler
  alias Earss.Retention
  alias Earss.Repo
  alias Earss.Reader.{Category, Subscription}
  alias Earss.Feeds.Feed

  @batch_refresh_limit 20

  # Parent router already ran parsers + session.
  plug(:match)
  plug(:fetch_flash_assign)
  plug(:protect_from_forgery)
  plug(Auth)
  plug(:dispatch)

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

  get "/subscriptions/:id" do
    with_user(conn, fn conn ->
      user = conn.assigns.admin_user

      case owned_sub(user, id) do
        nil ->
          conn |> put_flash(:err, "Not found") |> redirect("/admin/subscriptions")

        sub ->
          subscription_show(conn, sub)
      end
    end)
  end

  post "/subscriptions/:id" do
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
          back = referer_or(conn, "/admin/subscriptions/#{sub.id}")
          conn |> put_flash(:ok, "Hidden") |> redirect(back)
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
          back = referer_or(conn, "/admin/subscriptions/#{sub.id}")
          conn |> put_flash(:ok, "Unhidden") |> redirect(back)
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

  get "/categories" do
    with_user(conn, &categories_index/1)
  end

  post "/categories" do
    with_user(conn, fn conn ->
      user = conn.assigns.admin_user
      name = bp(conn, "name")
      position = empty_to_nil(bp(conn, "position"))

      attrs = %{name: name}

      attrs =
        if position do
          Map.put(attrs, :position, parse_int(position) || 0)
        else
          attrs
        end

      case Reader.create_category(user, attrs) do
        {:ok, _} ->
          conn |> put_flash(:ok, "Category created") |> redirect("/admin/categories")

        {:error, reason} ->
          conn
          |> put_flash(:err, "Could not create category: #{format_error(reason)}")
          |> redirect("/admin/categories")
      end
    end)
  end

  post "/categories/:id" do
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

  post "/categories/:id/delete" do
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

  get "/feeds" do
    with_user(conn, &feeds_index/1)
  end

  post "/feeds/refresh_batch" do
    with_user(conn, fn conn ->
      user = conn.assigns.admin_user
      ids = batch_ids(conn)

      if ids == [] do
        conn |> put_flash(:err, "No feeds selected") |> redirect("/admin/feeds")
      else
        {ok_n, fail_n, notes} = run_batch_refresh(user, ids)

        msg =
          "Batch refresh: #{ok_n} ok, #{fail_n} failed" <>
            if(notes == [], do: "", else: " — " <> Enum.join(Enum.take(notes, 3), "; "))

        type = if fail_n > 0 and ok_n == 0, do: :err, else: :ok

        conn
        |> put_flash(type, msg)
        |> redirect(referer_or(conn, "/admin/feeds"))
      end
    end)
  end

  post "/feeds/:id/refresh" do
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

  post "/feeds/:id/reenable" do
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

  get "/system" do
    with_admin(conn, &system_page/1)
  end

  post "/system/retention" do
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
          |> put_flash(:err, "Import failed: #{format_error(reason)}")
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

            {:error, reason} ->
              conn
              |> put_flash(:err, "Update failed: #{format_error(reason)}")
              |> redirect("/admin/settings")
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

          {:error, reason} ->
            conn
            |> put_flash(:err, "Failed: #{format_error(reason)}")
            |> redirect("/admin/settings")
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
    now = utc_now()
    subs = Reader.list_subscriptions(user, with_unread_count: true, include_hidden: true)
    unread = Enum.reduce(subs, 0, fn s, acc -> acc + (s.unread_count || 0) end)
    cats = Reader.list_categories(user)

    problem_subs =
      Enum.filter(subs, fn s ->
        f = s.feed
        f && (f.is_active == false or (is_integer(f.error_count) and f.error_count > 0))
      end)

    due_subs =
      Enum.filter(subs, fn s ->
        f = s.feed
        f && f.is_active && due_feed?(f, now)
      end)

    host = conn.host
    port = conn.port
    base = base_url(conn.scheme, host, port)
    fever_url = base <> "/fever/"
    greader_url = base <> "/api/greader.php"

    problem_rows =
      problem_subs
      |> Enum.take(8)
      |> Enum.map(fn s ->
        f = s.feed
        title = display_title(s)

        """
        <tr>
          <td><a href="/admin/subscriptions/#{s.id}">#{HTML.h(title)}</a>
            <div class="muted">#{HTML.h(f.link)}</div>
            #{if f.last_error, do: ~s(<div class="err-text">#{HTML.h(f.last_error)}</div>), else: ""}
          </td>
          <td>#{HTML.feed_status_badge(f)}</td>
          <td class="actions">
            <form method="post" action="/admin/feeds/#{f.id}/refresh">#{HTML.csrf_input()}<button type="submit">Refresh</button></form>
            <form method="post" action="/admin/feeds/#{f.id}/reenable">#{HTML.csrf_input()}<button type="submit" class="secondary">Re-enable</button></form>
          </td>
        </tr>
        """
      end)
      |> Enum.join("\n")

    due_rows =
      due_subs
      |> Enum.take(8)
      |> Enum.map(fn s ->
        f = s.feed
        title = display_title(s)

        """
        <tr>
          <td><a href="/admin/subscriptions/#{s.id}">#{HTML.h(title)}</a>
            <div class="muted">next: #{HTML.format_dt(f.next_fetch_at)}</div>
          </td>
          <td class="actions">
            <form method="post" action="/admin/feeds/#{f.id}/refresh">#{HTML.csrf_input()}<button type="submit">Refresh</button></form>
          </td>
        </tr>
        """
      end)
      |> Enum.join("\n")

    problem_block =
      if problem_rows == "" do
        ~s(<p class="empty">No problem feeds.</p>)
      else
        """
        <table class="compact-table">
          <thead><tr><th>Feed</th><th>Status</th><th></th></tr></thead>
          <tbody>#{problem_rows}</tbody>
        </table>
        """
      end

    due_block =
      if due_rows == "" do
        ~s(<p class="empty">Nothing due right now.</p>)
      else
        """
        <table class="compact-table">
          <thead><tr><th>Feed</th><th></th></tr></thead>
          <tbody>#{due_rows}</tbody>
        </table>
        """
      end

    inner = """
    <div class="card row">
      <div class="stat"><a href="/admin/subscriptions"><div class="muted">Subscriptions</div><div class="n">#{length(subs)}</div></a></div>
      <div class="stat"><a href="/admin/subscriptions?status=all"><div class="muted">Unread</div><div class="n">#{unread}</div></a></div>
      <div class="stat"><a href="/admin/categories"><div class="muted">Categories</div><div class="n">#{length(cats)}</div></a></div>
      <div class="stat"><a href="/admin/feeds?status=error"><div class="muted">Problem feeds</div><div class="n">#{length(problem_subs)}</div></a></div>
      <div class="stat"><a href="/admin/feeds?status=due"><div class="muted">Due now</div><div class="n">#{length(due_subs)}</div></a></div>
    </div>
    <div class="grid2">
      <div class="card">
        <h2>Problem feeds <a class="muted" href="/admin/feeds?status=error" style="font-size:12px;font-weight:500">view all</a></h2>
        #{problem_block}
      </div>
      <div class="card">
        <h2>Due feeds <a class="muted" href="/admin/feeds?status=due" style="font-size:12px;font-weight:500">view all</a></h2>
        #{due_block}
      </div>
    </div>
    <div class="card">
      <h2>NetNewsWire</h2>
      <p><strong>Fever</strong> URL: <code>#{HTML.h(fever_url)}</code></p>
      <p><strong>FreshRSS / GReader</strong> URL: <code>#{HTML.h(greader_url)}</code></p>
      <p class="muted">Username: <code>#{HTML.h(user.username)}</code> — password is login password or Fever-only secret (Settings).</p>
      <p class="muted">This admin manages sources; reading is in NNW.</p>
    </div>
    """

    html(conn, HTML.shell(user, flash(conn), "Dashboard", inner, active: "dashboard"))
  end

  defp subscriptions_index(conn) do
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

    cat_opts = category_options(cats, nil)
    filter_cat_opts = category_options(cats, category_id, include_all: true)

    rows =
      Enum.map(filtered, fn s ->
        title = display_title(s)
        cat_name = (s.category && s.category.name) || "—"
        unread = s.unread_count || 0
        f = s.feed
        status_badge = if f, do: HTML.feed_status_badge(f), else: HTML.badge("?", "muted")
        hidden_badge = if s.is_hidden, do: HTML.badge("hidden", "muted"), else: ""

        """
        <tr>
          <td>
            <a href="/admin/subscriptions/#{s.id}"><strong>#{HTML.h(title)}</strong></a>
            #{hidden_badge}
            <div class="muted">#{HTML.h(f && f.link)}</div>
          </td>
          <td>#{unread}</td>
          <td>#{HTML.h(cat_name)}</td>
          <td>#{status_badge}</td>
          <td class="muted">#{HTML.format_dt(f && f.next_fetch_at)}</td>
          <td class="actions stack-actions">
            <a class="btn secondary" href="/admin/subscriptions/#{s.id}">Edit</a>
            <form method="post" action="/admin/feeds/#{f.id}/refresh">#{HTML.csrf_input()}<button type="submit" class="secondary">Refresh</button></form>
            <form method="post" action="/admin/subscriptions/#{s.id}/unsubscribe" onsubmit="return confirm('Unsubscribe?')">#{HTML.csrf_input()}
              <button type="submit" class="danger">Unsub</button>
            </form>
          </td>
        </tr>
        """
      end)
      |> Enum.join("\n")

    empty_row =
      if rows == "" do
        ~s(<tr><td colspan="6" class="empty">No subscriptions match filters.</td></tr>)
      else
        rows
      end

    status_opts =
      option_list(
        [
          {"all", "All"},
          {"visible", "Visible"},
          {"hidden", "Hidden"},
          {"error", "Feed error"},
          {"disabled", "Feed disabled"},
          {"due", "Due now"}
        ],
        status
      )

    sort_opts =
      option_list(
        [
          {"title", "Title"},
          {"unread", "Unread"},
          {"next_fetch", "Next fetch"},
          {"id", "Newest"}
        ],
        sort
      )

    inner = """
    <div class="card">
      <h2>Add subscription</h2>
      <form method="post" action="/admin/subscriptions">#{HTML.csrf_input()}
        <label>Feed URL</label>
        <input name="link" type="url" required placeholder="https://example.com/feed.xml"/>
        <label>Title (optional)</label>
        <input name="title" placeholder="Display title"/>
        <label>Category</label>
        <select name="category_id">#{cat_opts}</select>
        <label class="inline-check"><input type="checkbox" name="refresh" value="true" checked/> Fetch now</label>
        <div><button type="submit">Subscribe</button></div>
      </form>
    </div>
    <div class="card">
      <form method="get" action="/admin/subscriptions" class="filters">
        <div class="field">
          <label>Search</label>
          <input name="q" value="#{HTML.h(q)}" placeholder="title or URL"/>
        </div>
        <div class="field">
          <label>Category</label>
          <select name="category_id">#{filter_cat_opts}</select>
        </div>
        <div class="field">
          <label>Status</label>
          <select name="status">#{status_opts}</select>
        </div>
        <div class="field">
          <label>Sort</label>
          <select name="sort">#{sort_opts}</select>
        </div>
        <div class="field">
          <button type="submit">Filter</button>
          <a class="btn secondary" href="/admin/subscriptions">Reset</a>
        </div>
      </form>
      <p class="muted">Showing #{length(filtered)} / #{length(subs)}</p>
      <table>
        <thead>
          <tr>
            <th>Feed</th><th>Unread</th><th>Category</th><th>Status</th><th>Next fetch</th><th></th>
          </tr>
        </thead>
        <tbody>#{empty_row}</tbody>
      </table>
    </div>
    """

    html(conn, HTML.shell(user, flash(conn), "Subscriptions", inner, active: "subscriptions"))
  end

  defp subscription_show(conn, sub) do
    user = conn.assigns.admin_user
    cats = Reader.list_categories(user)
    f = sub.feed
    now = utc_now()
    title = display_title(sub)
    effective = if f, do: FeedScheduler.effective_interval(f), else: nil
    cat_opts = category_options(cats, sub.category_id && to_string(sub.category_id))
    hidden_checked = if sub.is_hidden, do: "checked", else: ""

    interval_val =
      case sub.custom_refresh_interval do
        n when is_integer(n) -> to_string(n)
        _ -> ""
      end

    custom_title_val = sub.custom_title || ""

    feed_block =
      if f do
        due_cls = HTML.due_class(f.next_fetch_at, now)

        """
        <div class="card">
          <h2>Feed (shared) #{HTML.feed_status_badge(f)}</h2>
          <dl class="kv">
            <dt>URL</dt><dd><code>#{HTML.h(f.link)}</code></dd>
            <dt>Title</dt><dd>#{HTML.h(f.title || "—")}</dd>
            <dt>Type</dt><dd>#{HTML.h(f.feed_type)}</dd>
            <dt>Site</dt><dd>#{HTML.h(f.site_url || "—")}</dd>
            <dt>Active</dt><dd>#{if f.is_active, do: "yes", else: "no"}</dd>
            <dt>Errors</dt><dd>#{f.error_count}</dd>
            <dt>Last error</dt><dd class="err-text">#{HTML.h(f.last_error || "—")}</dd>
            <dt>Last fetch</dt><dd>#{HTML.format_dt(f.last_fetched_at)}</dd>
            <dt>Next fetch</dt><dd class="#{due_cls}">#{HTML.format_dt(f.next_fetch_at)}</dd>
            <dt>Interval</dt><dd>#{f.refresh_interval} min (stored)</dd>
            <dt>Effective</dt><dd>#{effective || "—"} min (D1)</dd>
            <dt>Min / max</dt><dd>#{f.min_refresh_interval} / #{f.max_refresh_interval}</dd>
            <dt>Unchanged streak</dt><dd>#{f.unchanged_fetch_count}</dd>
            <dt>Last new entry</dt><dd>#{HTML.format_dt(f.last_new_entry_at)}</dd>
          </dl>
          <div class="stack-actions" style="margin-top:1rem">
            <form method="post" action="/admin/feeds/#{f.id}/refresh">#{HTML.csrf_input()}
              <input type="hidden" name="return_to" value="/admin/subscriptions/#{sub.id}"/>
              <button type="submit">Refresh now</button>
            </form>
            <form method="post" action="/admin/feeds/#{f.id}/reenable">#{HTML.csrf_input()}
              <input type="hidden" name="return_to" value="/admin/subscriptions/#{sub.id}"/>
              <button type="submit" class="secondary">Re-enable</button>
            </form>
          </div>
        </div>
        """
      else
        ~s(<div class="card"><p class="err-text">Feed missing</p></div>)
      end

    inner = """
    <p class="muted"><a href="/admin/subscriptions">← Subscriptions</a></p>
    <div class="grid2">
      <div class="card">
        <h2>Your subscription</h2>
        <form method="post" action="/admin/subscriptions/#{sub.id}">#{HTML.csrf_input()}
          <label>Display title</label>
          <input name="custom_title" value="#{HTML.h(custom_title_val)}" placeholder="#{HTML.h((f && f.title) || "optional")}"/>
          <label>Custom refresh interval (minutes, blank = follow feed)</label>
          <input name="custom_refresh_interval" type="number" min="1" value="#{HTML.h(interval_val)}" placeholder="e.g. 30"/>
          <label>Category</label>
          <select name="category_id">#{cat_opts}</select>
          <label class="inline-check">
            <input type="checkbox" name="is_hidden" value="true" #{hidden_checked}/> Hidden (excluded from D1 interval)
          </label>
          <div class="stack-actions" style="margin-top:.75rem">
            <button type="submit">Save</button>
            <a class="btn secondary" href="/admin/subscriptions">Cancel</a>
          </div>
        </form>
        <hr style="border:none;border-top:1px solid var(--line);margin:1.25rem 0"/>
        <form method="post" action="/admin/subscriptions/#{sub.id}/unsubscribe" onsubmit="return confirm('Unsubscribe from this feed?')">#{HTML.csrf_input()}
          <button type="submit" class="danger">Unsubscribe</button>
        </form>
      </div>
      #{feed_block}
    </div>
    <div class="card">
      <p class="muted">Editing title / interval / category only affects your account. Refresh updates the shared feed crawl for all subscribers.</p>
      <p class="muted">Current display: <strong>#{HTML.h(title)}</strong></p>
    </div>
    """

    html(
      conn,
      HTML.shell(user, flash(conn), "Subscription · #{title}", inner, active: "subscriptions")
    )
  end

  defp categories_index(conn) do
    user = conn.assigns.admin_user
    cats = Reader.list_categories(user)
    counts = subscription_counts_by_category(user.id)

    rows =
      Enum.map(cats, fn c ->
        n = Map.get(counts, c.id, 0)

        """
        <tr>
          <td>
            <form method="post" action="/admin/categories/#{c.id}" class="stack-actions">#{HTML.csrf_input()}
              <input name="name" value="#{HTML.h(c.name)}" required style="max-width:220px"/>
              <input name="position" type="number" min="0" value="#{c.position}" style="max-width:90px"/>
              <button type="submit" class="secondary">Save</button>
            </form>
          </td>
          <td>#{n}</td>
          <td class="actions">
            <a class="btn secondary" href="/admin/subscriptions?category_id=#{c.id}">View</a>
            <form method="post" action="/admin/categories/#{c.id}/delete" onsubmit="return confirm('Delete category? Subscriptions keep their feeds.')">#{HTML.csrf_input()}
              <button type="submit" class="danger">Delete</button>
            </form>
          </td>
        </tr>
        """
      end)
      |> Enum.join("\n")

    empty =
      if rows == "" do
        ~s(<tr><td colspan="3" class="empty">No categories yet.</td></tr>)
      else
        rows
      end

    inner = """
    <div class="card">
      <h2>Create</h2>
      <form method="post" action="/admin/categories" class="filters">#{HTML.csrf_input()}
        <div class="field">
          <label>Name</label>
          <input name="name" required/>
        </div>
        <div class="field">
          <label>Position</label>
          <input name="position" type="number" min="0" value="0"/>
        </div>
        <div class="field">
          <button type="submit">Create</button>
        </div>
      </form>
    </div>
    <div class="card">
      <table>
        <thead><tr><th>Name / position</th><th>Subs</th><th></th></tr></thead>
        <tbody>#{empty}</tbody>
      </table>
    </div>
    """

    html(conn, HTML.shell(user, flash(conn), "Categories", inner, active: "categories"))
  end

  defp feeds_index(conn) do
    user = conn.assigns.admin_user
    params = conn.query_params || %{}
    status = Map.get(params, "status") || "all"
    q = Map.get(params, "q") |> empty_to_nil()
    now = utc_now()

    subs =
      Reader.list_subscriptions(user, include_hidden: true)
      |> filter_subs_q(q)
      |> filter_feeds_status(status, now)

    status_opts =
      option_list(
        [
          {"all", "All"},
          {"active", "Active"},
          {"disabled", "Disabled"},
          {"error", "Error"},
          {"due", "Due now"}
        ],
        status
      )

    rows =
      Enum.map(subs, fn s ->
        f = s.feed
        title = display_title(s)
        due_cls = HTML.due_class(f.next_fetch_at, now)

        """
        <tr>
          <td>
            <label class="inline-check" style="margin:0">
              <input type="checkbox" name="ids[]" value="#{f.id}" form="batch-refresh"/>
              <span>
                <a href="/admin/subscriptions/#{s.id}"><strong>#{HTML.h(title)}</strong></a>
                <div class="muted">#{HTML.h(f.link)}</div>
                #{if f.last_error, do: ~s(<div class="err-text">#{HTML.h(f.last_error)}</div>), else: ""}
              </span>
            </label>
          </td>
          <td>#{HTML.feed_status_badge(f)}</td>
          <td>#{f.error_count}</td>
          <td class="muted">#{HTML.format_dt(f.last_fetched_at)}</td>
          <td class="#{due_cls}">#{HTML.format_dt(f.next_fetch_at)}</td>
          <td class="muted">#{f.refresh_interval}m / eff #{FeedScheduler.effective_interval(f)}m</td>
          <td class="actions stack-actions">
            <form method="post" action="/admin/feeds/#{f.id}/refresh">#{HTML.csrf_input()}<button type="submit">Refresh</button></form>
            <form method="post" action="/admin/feeds/#{f.id}/reenable">#{HTML.csrf_input()}<button type="submit" class="secondary">Re-enable</button></form>
          </td>
        </tr>
        """
      end)
      |> Enum.join("\n")

    empty =
      if rows == "" do
        ~s(<tr><td colspan="7" class="empty">No feeds match.</td></tr>)
      else
        rows
      end

    inner = """
    <div class="card">
      <p class="muted">Feeds you subscribe to. Refresh runs a single fetch; re-enable clears the error circuit-breaker. Batch refresh max #{@batch_refresh_limit}.</p>
      <form method="get" action="/admin/feeds" class="filters">
        <div class="field">
          <label>Search</label>
          <input name="q" value="#{HTML.h(q)}" placeholder="title or URL"/>
        </div>
        <div class="field">
          <label>Status</label>
          <select name="status">#{status_opts}</select>
        </div>
        <div class="field">
          <button type="submit">Filter</button>
          <a class="btn secondary" href="/admin/feeds">Reset</a>
        </div>
      </form>
      <form id="batch-refresh" method="post" action="/admin/feeds/refresh_batch" class="stack-actions" style="margin:.75rem 0">#{HTML.csrf_input()}
        <button type="submit">Refresh selected</button>
        <span class="muted">Select rows below (max #{@batch_refresh_limit})</span>
      </form>
      <table class="compact-table">
        <thead>
          <tr>
            <th>Feed</th><th>Status</th><th>Errors</th><th>Last fetch</th><th>Next</th><th>Interval</th><th></th>
          </tr>
        </thead>
        <tbody>#{empty}</tbody>
      </table>
    </div>
    """

    html(conn, HTML.shell(user, flash(conn), "Feeds", inner, active: "feeds"))
  end

  defp system_page(conn) do
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

    due_rows =
      due
      |> Enum.map(fn f ->
        """
        <tr>
          <td>#{HTML.h(f.title || f.link)}
            <div class="muted">#{HTML.h(f.link)}</div>
          </td>
          <td class="muted">#{HTML.format_dt(f.next_fetch_at)}</td>
          <td>#{f.error_count}</td>
          <td class="actions">
            <form method="post" action="/admin/feeds/#{f.id}/refresh">#{HTML.csrf_input()}
              <input type="hidden" name="return_to" value="/admin/system"/>
              <button type="submit">Refresh</button>
            </form>
          </td>
        </tr>
        """
      end)
      |> Enum.join("\n")

    due_block =
      if due_rows == "" do
        ~s(<p class="empty">No due feeds.</p>)
      else
        """
        <table class="compact-table">
          <thead><tr><th>Feed</th><th>Next</th><th>Errors</th><th></th></tr></thead>
          <tbody>#{due_rows}</tbody>
        </table>
        """
      end

    inner = """
    <div class="card row">
      <div class="stat"><div class="muted">Due (global)</div><div class="n">#{due_total}</div></div>
      <div class="stat"><div class="muted">Disabled</div><div class="n">#{disabled}</div></div>
      <div class="stat"><div class="muted">With errors</div><div class="n">#{errors}</div></div>
    </div>
    <div class="grid2">
      <div class="card">
        <h2>Config (read-only)</h2>
        <dl class="kv">
          <dt>Refresh default</dt><dd>#{Keyword.get(refresh, :default_interval)} min</dd>
          <dt>Refresh min/max</dt><dd>#{Keyword.get(refresh, :min_interval)} / #{Keyword.get(refresh, :max_interval)}</dd>
          <dt>Retention states</dt><dd>#{Keyword.get(retention, :read_state_days)} days</dd>
          <dt>Retention entries</dt><dd>#{Keyword.get(retention, :entry_days)} days</dd>
          <dt>Unsubscribed feeds</dt><dd>#{Keyword.get(retention, :unsubscribed_feed_days)} days</dd>
          <dt>Poller</dt><dd>#{on_off(Keyword.get(poller, :enabled, true))} · every #{Keyword.get(poller, :interval_ms)} ms · batch #{Keyword.get(poller, :batch_size)}</dd>
          <dt>Retention poller</dt><dd>#{on_off(Keyword.get(ret_poller, :enabled, true))} · every #{Keyword.get(ret_poller, :interval_ms)} ms</dd>
          <dt>API</dt><dd>#{on_off(Keyword.get(api, :enabled, true))} · port #{Keyword.get(api, :port)}</dd>
        </dl>
      </div>
      <div class="card">
        <h2>Retention (admin only)</h2>
        <p class="muted">Level A states → B entries → C unsubscribed feeds. Prefer dry run first.</p>
        <form method="post" action="/admin/system/retention" class="stack-actions">#{HTML.csrf_input()}
          <button type="submit" name="mode" value="dry_run" class="secondary">Dry run</button>
          <button type="submit" name="mode" value="run" class="danger" onclick="return confirm('Run retention deletes now?')">Run cleanup</button>
        </form>
      </div>
    </div>
    <div class="card">
      <h2>Due snapshot (up to 20 of #{due_total})</h2>
      #{due_block}
    </div>
    """

    html(conn, HTML.shell(user, flash(conn), "System", inner, active: "system"))
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
      <form method="post" action="/admin/opml/import">#{HTML.csrf_input()}
        <textarea name="opml" required placeholder="&lt;opml ...&gt;"></textarea>
        <div><button type="submit">Import</button></div>
      </form>
    </div>
    """

    html(conn, HTML.shell(user, flash(conn), "OPML", inner, active: "opml"))
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

    fever_url = base_url(conn.scheme, conn.host, conn.port) <> "/fever/"

    inner = """
    <div class="card">
      <h2>Fever / NetNewsWire</h2>
      <p>URL: <code>#{HTML.h(fever_url)}</code></p>
      <p>Username: <code>#{HTML.h(user.username)}</code></p>
      <p class="muted">Stored api_key fingerprint: <code>#{HTML.h(key_short)}</code></p>
      <form method="post" action="/admin/settings/fever">#{HTML.csrf_input()}
        <label>Fever-only password/secret (does not change login password)</label>
        <input name="fever_secret" type="password" autocomplete="new-password"/>
        <button type="submit">Set Fever secret</button>
      </form>
    </div>
    <div class="card">
      <h2>Login password</h2>
      <p class="muted">Also recomputes Fever api_key from username:new_password.</p>
      <form method="post" action="/admin/settings/password">#{HTML.csrf_input()}
        <label>New password</label>
        <input name="password" type="password" autocomplete="new-password" required/>
        <label>Confirm</label>
        <input name="password_confirm" type="password" autocomplete="new-password" required/>
        <button type="submit">Update password</button>
      </form>
    </div>
    """

    html(conn, HTML.shell(user, flash(conn), "Settings", inner, active: "settings"))
  end

  ## helpers

  defp with_user(conn, fun) do
    conn = Auth.require_user(conn, [])
    if conn.halted, do: conn, else: fun.(conn)
  end

  defp with_admin(conn, fun) do
    conn = Auth.require_admin(conn, [])
    if conn.halted, do: conn, else: fun.(conn)
  end

  defp owned_sub(user, id) do
    id = parse_int(id)

    case id && Repo.get(Subscription, id) do
      %Subscription{user_id: uid} = sub when uid == user.id ->
        Repo.preload(sub, [:feed, :category])

      _ ->
        nil
    end
  end

  defp owned_category(user, id) do
    id = parse_int(id)

    case id && Reader.get_category(id) do
      %Category{user_id: uid} = cat when uid == user.id -> cat
      _ -> nil
    end
  end

  defp authorized_feed(user, feed_id) do
    cond do
      is_nil(feed_id) ->
        :forbidden

      Auth.admin?(user) ->
        :ok

      Reader.get_subscription(user, feed_id) ->
        :ok

      true ->
        :forbidden
    end
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

  defp display_title(sub) do
    sub.custom_title || (sub.feed && (sub.feed.title || sub.feed.link)) || "subscription ##{sub.id}"
  end

  defp filter_subs_q(subs, nil), do: subs

  defp filter_subs_q(subs, q) do
    q = String.downcase(q)

    Enum.filter(subs, fn s ->
      title = String.downcase(display_title(s) || "")
      link = String.downcase((s.feed && s.feed.link) || "")
      String.contains?(title, q) or String.contains?(link, q)
    end)
  end

  defp filter_subs_category(subs, nil), do: subs
  defp filter_subs_category(subs, ""), do: subs

  defp filter_subs_category(subs, "none") do
    Enum.filter(subs, &is_nil(&1.category_id))
  end

  defp filter_subs_category(subs, cat_id) do
    case parse_int(cat_id) do
      nil -> subs
      id -> Enum.filter(subs, &(&1.category_id == id))
    end
  end

  defp filter_subs_status(subs, "all", _now), do: subs
  defp filter_subs_status(subs, "visible", _now), do: Enum.reject(subs, & &1.is_hidden)
  defp filter_subs_status(subs, "hidden", _now), do: Enum.filter(subs, & &1.is_hidden)

  defp filter_subs_status(subs, "error", _now) do
    Enum.filter(subs, fn s ->
      f = s.feed
      f && f.is_active && is_integer(f.error_count) && f.error_count > 0
    end)
  end

  defp filter_subs_status(subs, "disabled", _now) do
    Enum.filter(subs, fn s -> s.feed && s.feed.is_active == false end)
  end

  defp filter_subs_status(subs, "due", now) do
    Enum.filter(subs, fn s -> s.feed && s.feed.is_active && due_feed?(s.feed, now) end)
  end

  defp filter_subs_status(subs, _, _), do: subs

  defp filter_feeds_status(subs, "all", _now), do: subs

  defp filter_feeds_status(subs, "active", _now) do
    Enum.filter(subs, fn s -> s.feed && s.feed.is_active && s.feed.error_count == 0 end)
  end

  defp filter_feeds_status(subs, "disabled", _now) do
    Enum.filter(subs, fn s -> s.feed && s.feed.is_active == false end)
  end

  defp filter_feeds_status(subs, "error", _now) do
    Enum.filter(subs, fn s ->
      f = s.feed
      f && (f.is_active == false || (is_integer(f.error_count) && f.error_count > 0))
    end)
  end

  defp filter_feeds_status(subs, "due", now) do
    Enum.filter(subs, fn s -> s.feed && s.feed.is_active && due_feed?(s.feed, now) end)
  end

  defp filter_feeds_status(subs, _, _), do: subs

  defp sort_subs(subs, "unread") do
    Enum.sort_by(subs, fn s -> {-(s.unread_count || 0), s.id} end)
  end

  defp sort_subs(subs, "next_fetch") do
    Enum.sort_by(subs, fn s ->
      next = s.feed && s.feed.next_fetch_at
      {is_nil(next), next, s.id}
    end)
  end

  defp sort_subs(subs, "id") do
    Enum.sort_by(subs, & &1.id, :desc)
  end

  defp sort_subs(subs, _) do
    Enum.sort_by(subs, fn s -> String.downcase(display_title(s) || "") end)
  end

  defp due_feed?(%Feed{next_fetch_at: nil}, _now), do: true

  defp due_feed?(%Feed{next_fetch_at: next}, now) do
    DateTime.compare(next, now) != :gt
  end

  defp due_feed?(_, _), do: false

  defp category_options(cats, selected, opts \\ []) do
    include_all? = Keyword.get(opts, :include_all, false)

    head =
      cond do
        include_all? ->
          [
            option_tag("", "All categories", selected in [nil, ""]),
            option_tag("none", "— uncategorized —", selected == "none")
          ]

        true ->
          [option_tag("", "— none —", selected in [nil, ""])]
      end

    rest =
      Enum.map(cats, fn c ->
        option_tag(to_string(c.id), c.name, selected == to_string(c.id))
      end)

    Enum.join(head ++ rest, "")
  end

  defp option_list(pairs, selected) do
    pairs
    |> Enum.map(fn {val, label} -> option_tag(val, label, selected == val) end)
    |> Enum.join("")
  end

  defp option_tag(value, label, true) do
    ~s(<option value="#{HTML.h(value)}" selected>#{HTML.h(label)}</option>)
  end

  defp option_tag(value, label, false) do
    ~s(<option value="#{HTML.h(value)}">#{HTML.h(label)}</option>)
  end

  defp subscription_counts_by_category(user_id) do
    from(s in Subscription,
      where: s.user_id == ^user_id and not is_nil(s.category_id),
      group_by: s.category_id,
      select: {s.category_id, count(s.id)}
    )
    |> Repo.all()
    |> Map.new()
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
    |> Enum.take(@batch_refresh_limit)
  end

  defp run_batch_refresh(user, ids) do
    Enum.reduce(ids, {0, 0, []}, fn feed_id, {ok_n, fail_n, notes} ->
      case authorized_feed(user, feed_id) do
        :ok ->
          case Feeds.refresh(feed_id, force: true) do
            {:ok, _} ->
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

  defp refresh_redirect(conn, _feed_id) do
    case empty_to_nil(bp(conn, "return_to")) do
      path when is_binary(path) ->
        if String.starts_with?(path, "/admin"), do: path, else: "/admin/feeds"

      _ ->
        referer_or(conn, "/admin/feeds")
    end
  end

  defp referer_or(conn, default) do
    case Plug.Conn.get_req_header(conn, "referer") do
      [ref | _] ->
        uri = URI.parse(ref)

        if is_binary(uri.path) and String.starts_with?(uri.path, "/admin") do
          uri.path <> if(uri.query, do: "?" <> uri.query, else: "")
        else
          default
        end

      _ ->
        default
    end
  end

  defp base_url(scheme, host, port) do
    if port in [80, 443] do
      "#{scheme}://#{host}"
    else
      "#{scheme}://#{host}:#{port}"
    end
  end

  defp on_off(true), do: "on"
  defp on_off(_), do: "off"

  defp format_error(%Ecto.Changeset{} = cs) do
    cs
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.map(fn {field, msgs} -> "#{field} #{Enum.join(msgs, ", ")}" end)
    |> Enum.join("; ")
  end

  defp format_error(reason) when is_atom(reason), do: to_string(reason)
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  defp parse_int(nil), do: nil
  defp parse_int(i) when is_integer(i), do: i

  defp parse_int(s) when is_binary(s) do
    case Integer.parse(String.trim(s)) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parse_int(_), do: nil

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

  defp utc_now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
