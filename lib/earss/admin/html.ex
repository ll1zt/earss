defmodule Earss.Admin.HTML do
  @moduledoc false

  def layout(title, flash, body) do
    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="utf-8"/>
      <meta name="viewport" content="width=device-width, initial-scale=1"/>
      <title>#{h(title)} · Earss Admin</title>
      <link rel="stylesheet" href="/static/admin.css"/>
      <script src="/static/admin.js" defer></script>
    </head>
    <body>
      #{body}
    </body>
    </html>
    """
    |> maybe_flash(flash)
  end

  defp maybe_flash(html, nil), do: html
  defp maybe_flash(html, {_, nil}), do: html
  defp maybe_flash(html, {_, ""}), do: html

  defp maybe_flash(html, {type, msg}) do
    String.replace(html, "<!--FLASH-->", ~s(<div class="flash #{type}">#{h(msg)}</div>),
      global: false
    )
  end

  def shell(user, flash, title, inner, opts \\ []) do
    active = Keyword.get(opts, :active, "")

    nav_link = fn path, label, key ->
      cls = if active == key, do: ~s( class="active"), else: ""
      ~s(<a href="#{path}"#{cls}>#{label}</a>)
    end

    nav = """
    <header class="topbar">
      <span class="brand">EARSS <span class="brand-sub">// console</span></span>
      <nav>
        #{nav_link.("/admin", "Dashboard", "dashboard")}
        #{nav_link.("/admin/subscriptions", "Subscriptions", "subscriptions")}
        #{nav_link.("/admin/sources", "Sources", "sources")}
        #{nav_link.("/admin/categories", "Categories", "categories")}
        #{nav_link.("/admin/feeds", "Feeds", "feeds")}
        #{nav_link.("/admin/system", "System", "system")}
        #{nav_link.("/admin/metrics", "Metrics", "metrics")}
        #{nav_link.("/admin/opml", "OPML", "opml")}
        #{nav_link.("/admin/export", "Export", "export")}
        #{if Earss.Enrichment.enricher() != nil, do: nav_link.("/admin/translate", "Translate", "translate")}
        #{nav_link.("/admin/settings", "Settings", "settings")}
      </nav>
      <div class="topbar-end">
        <span class="user-chip">#{h(user.username)}@earss</span>
        <form method="post" action="/admin/logout" class="inline-form">
          #{csrf_input()}
          <button type="submit" class="secondary">Log out</button>
        </form>
      </div>
    </header>
    <main>
      <!--FLASH-->
      <h1>#{h(title)}</h1>
      #{inner}
    </main>
    """

    layout(title, flash, nav)
  end

  def login_page(flash, error \\ nil) do
    err =
      if error do
        ~s(<div class="flash err">#{h(error)}</div>)
      else
        "<!--FLASH-->"
      end

    body = """
    <div class="login-wrap">
      <main class="login-main">
        <div class="card login-card">
          <p class="login-kicker">operator access</p>
          <h1>EARSS login</h1>
          #{err}
          <form method="post" action="/admin/login">
            #{csrf_input()}
            <label>Operator password</label>
            <input name="password" type="password" autocomplete="current-password" required/>
            <button type="submit">Sign in</button>
          </form>
        </div>
        <p class="muted login-foot">Single-operator mode: the password is <code>ADMIN_PASSWORD</code> from <code>earss.env</code>. Reading: NetNewsWire via <a href="/fever/">Fever</a> or FreshRSS/GReader <code>/api/greader.php</code>.</p>
      </main>
    </div>
    """

    layout("Login", flash, body)
  end

  def csrf_input do
    token = Plug.CSRFProtection.get_csrf_token()
    ~s(<input type="hidden" name="_csrf_token" value="#{h(token)}"/>)
  end

  def h(nil), do: ""

  def h(str) do
    str
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  def format_dt(nil), do: "—"

  def format_dt(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M") <> " UTC"
  end

  def format_dt(other), do: h(other)

  def badge(text, type \\ "muted") do
    ~s(<span class="badge #{type}">#{h(text)}</span>)
  end

  def feed_status_badge(%{is_active: false}), do: badge("disabled", "err")

  def feed_status_badge(%{error_count: n}) when is_integer(n) and n > 0,
    do: badge("error", "err")

  def feed_status_badge(_), do: badge("active", "ok")

  def due_class(nil, _now), do: "warn-text"

  def due_class(%DateTime{} = next, now) do
    if DateTime.compare(next, now) != :gt, do: "warn-text", else: "muted"
  end

  def due_class(_, _), do: "muted"
end
