defmodule Earss.Admin.Router do
  @moduledoc """
  Server-rendered admin UI at `/admin` (admin-v0.2).

  Routes dispatch into `Earss.Admin.Controllers.*`; shared helpers live in
  `Earss.Admin.Helpers` and `Earss.Admin.ControllerHelpers`.
  """

  use Plug.Router

  import Ecto.Query, warn: false
  import Plug.Conn

  import Earss.Admin.Helpers, except: [fetch_flash_assign: 2]
  import Earss.Admin.ControllerHelpers

  alias Earss.Admin.{Auth, HTML}
  alias Earss.Admin.Controllers.{Dashboard, Session, Subscriptions}
  alias Earss.Reader
  alias Earss.Feeds
  alias Earss.FeedScheduler
  alias Earss.Retention
  alias Earss.Repo
  alias Earss.Reader.Subscription
  alias Earss.Feeds.Feed

  @batch_refresh_limit 20

  # Parent router already ran parsers + session.
  plug(:match)
  plug(:fetch_flash_assign)
  plug(:protect_from_forgery)
  plug(Auth)
  plug(:dispatch)

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

  ## Pages (remaining; migrate to Controllers/Views)

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

  ## page-local helpers (controller-specific; will move with controllers)

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
end
