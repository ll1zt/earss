defmodule Earss.Admin.HTML do
  @moduledoc false

  alias Earss.Admin.Theme

  def layout(title, flash, body) do
    theme = Theme.current()

    """
    <!DOCTYPE html>
    <html lang="en" data-theme="#{h(theme)}">
    <head>
      <meta charset="utf-8"/>
      <meta name="viewport" content="width=device-width, initial-scale=1"/>
      <title>#{h(title)} · Earss Admin</title>
      <style>
        #{theme_css()}
      </style>
    </head>
    <body class="admin-theme admin-theme--#{h(theme)}">
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
    theme = Theme.current()

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
        #{nav_link.("/admin/opml", "OPML", "opml")}
        #{nav_link.("/admin/export", "Export", "export")}
        #{if Earss.Enrichment.enricher() != nil, do: nav_link.("/admin/translate", "Translate", "translate")}
        #{nav_link.("/admin/settings", "Settings", "settings")}
      </nav>
      <div class="topbar-end">
        #{theme_switcher(theme)}
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
    theme = Theme.current()

    err =
      if error do
        ~s(<div class="flash err">#{h(error)}</div>)
      else
        "<!--FLASH-->"
      end

    body = """
    <div class="login-wrap">
      <div class="login-theme">#{theme_switcher(theme)}</div>
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

  def theme_switcher(current \\ Theme.current()) do
    links =
      Theme.themes()
      |> Enum.map(fn t ->
        label = Theme.label(t)
        active? = t == current
        cls = if active?, do: "theme-link active", else: "theme-link"

        """
        <form method="post" action="/admin/theme" class="theme-form">
          #{csrf_input()}
          <input type="hidden" name="theme" value="#{h(t)}"/>
          <button type="submit" class="#{cls}" #{if active?, do: "disabled", else: ""}>#{h(label)}</button>
        </form>
        """
      end)
      |> Enum.join("")

    ~s(<div class="theme-switch" title="UI theme">#{links}</div>)
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

  # —— themes: A CRT console + C paper magazine ——

  defp theme_css do
    """
    /* shared layout */
    * { box-sizing: border-box; }
    body { margin: 0; }
    a { color: var(--acc); text-decoration: none; }
    a:hover { text-decoration: underline; }
    main { max-width: 1100px; margin: 1.25rem auto; padding: 0 1rem 3rem; }
    .topbar {
      display: flex; flex-wrap: wrap; gap: 0.75rem 1rem; align-items: center;
      padding: 0.65rem 1.15rem; border-bottom: 2px solid var(--line-hi);
      background: var(--titlebar); color: var(--text);
    }
    .brand { font-weight: 700; letter-spacing: 0.06em; margin-right: 0.35rem; }
    .brand-sub { font-weight: 500; opacity: 0.7; font-size: 0.85em; letter-spacing: 0.04em; }
    .topbar nav a { margin-right: 0.85rem; color: var(--muted); }
    .topbar nav a:hover, .topbar nav a.active { color: var(--acc); }
    .topbar nav a.active { font-weight: 700; text-decoration: underline; text-underline-offset: 4px; }
    .topbar-end { margin-left: auto; display: flex; flex-wrap: wrap; align-items: center; gap: 0.5rem 0.75rem; }
    .user-chip { color: var(--muted); font-size: 12px; }
    .inline-form { margin: 0; display: inline; }
    .theme-switch { display: inline-flex; gap: 0.2rem; align-items: center; }
    .theme-form { margin: 0; display: inline; }
    .theme-link {
      margin: 0 !important; padding: 0.15rem 0.45rem !important; font-size: 11px !important;
      font-weight: 600; cursor: pointer;
    }
    .theme-link:disabled, .theme-link.active { cursor: default; opacity: 1; }
    h1 { font-size: 1.35rem; margin: 0 0 1rem; }
    h2 { font-size: 1.0rem; margin: 0 0 0.75rem; color: var(--muted); font-weight: 600; }
    .card {
      background: var(--card); border: 1px solid var(--line); padding: 1rem 1.15rem;
      margin-bottom: 1rem; border-radius: var(--radius);
    }
    .card > h2 {
      margin: -1rem -1.15rem 0.85rem; padding: 0.45rem 1.15rem;
      background: var(--panel-hd); border-bottom: 1px solid var(--line);
      color: var(--panel-hd-text); font-size: 0.95rem; letter-spacing: 0.04em;
    }
    table { width: 100%; border-collapse: collapse; font-size: 13px; }
    th, td { text-align: left; padding: 0.4rem 0.35rem; border-bottom: 1px solid var(--line); vertical-align: top; }
    th { color: var(--muted); font-weight: 600; white-space: nowrap; letter-spacing: 0.03em; }
    .muted { color: var(--muted); }
    .flash { padding: 0.6rem 0.85rem; margin-bottom: 1rem; border: 1px solid var(--line); border-radius: var(--radius); }
    .flash.ok { background: var(--flash-ok-bg); color: var(--flash-ok-fg); border-color: var(--ok); }
    .flash.err { background: var(--flash-err-bg); color: var(--flash-err-fg); border-color: var(--err); }
    .flash.ok::before { content: "OK · "; font-weight: 700; }
    .flash.err::before { content: "ERR · "; font-weight: 700; }
    label { display: block; margin: 0.4rem 0 0.2rem; color: var(--muted); font-size: 12px; letter-spacing: 0.04em; text-transform: uppercase; }
    input, select, textarea {
      width: 100%; max-width: 420px; padding: 0.45rem 0.55rem; border-radius: var(--radius-sm);
      border: 1px solid var(--line); background: var(--input-bg); color: var(--text); font: inherit;
    }
    input:focus, select:focus, textarea:focus { outline: 2px solid var(--acc); outline-offset: 1px; }
    textarea { min-height: 120px; max-width: 100%; font-family: var(--font-mono); font-size: 13px; }
    button, .btn {
      display: inline-block; margin-top: 0.5rem; margin-right: 0.4rem; padding: 0.4rem 0.75rem;
      border-radius: var(--radius-sm); border: 1px solid var(--btn-border); background: var(--btn-bg);
      color: var(--btn-fg); font-weight: 700; cursor: pointer; font-size: 13px; text-decoration: none; font-family: inherit;
    }
    button:active, .btn:active { transform: translate(1px, 1px); }
    a.btn:hover { text-decoration: none; filter: brightness(1.05); }
    button.secondary, .btn.secondary { background: transparent; color: var(--text); border-color: var(--line-hi); }
    button.danger, .btn.danger { background: var(--err); color: var(--btn-danger-fg); border-color: var(--err); }
    .row { display: flex; flex-wrap: wrap; gap: 1rem; }
    .stat { flex: 1; min-width: 120px; }
    .stat a { color: inherit; text-decoration: none; display: block; }
    .stat a:hover .n { color: var(--acc); }
    .stat .n { font-size: 1.55rem; font-weight: 700; font-variant-numeric: tabular-nums; }
    .err-text { color: var(--err); font-size: 12px; }
    .warn-text { color: var(--warn); font-size: 12px; }
    code { background: var(--code-bg); padding: 0.1rem 0.3rem; border-radius: var(--radius-sm); font-size: 12px; border: 1px solid var(--line); }
    .actions form { display: inline; }
    .actions button, .actions .btn { margin-top: 0; }
    .filters { display: flex; flex-wrap: wrap; gap: 0.65rem 1rem; align-items: flex-end; margin-bottom: 0.25rem; }
    .filters .field { min-width: 120px; }
    .filters input, .filters select { max-width: 220px; margin: 0; }
    .filters button { margin-top: 0; }
    .badge {
      display: inline-block; padding: 0.1rem 0.4rem; font-size: 11px; font-weight: 700;
      line-height: 1.4; border: 1px solid var(--line); border-radius: var(--radius-sm);
      text-transform: lowercase; letter-spacing: 0.02em;
    }
    .badge.ok { background: var(--badge-ok-bg); color: var(--ok); border-color: var(--ok); }
    .badge.err { background: var(--badge-err-bg); color: var(--err); border-color: var(--err); }
    .badge.warn { background: var(--badge-warn-bg); color: var(--warn); border-color: var(--warn); }
    .badge.muted { background: var(--badge-muted-bg); color: var(--muted); }
    .grid2 { display: grid; grid-template-columns: 1fr 1fr; gap: 1rem; }
    @media (max-width: 800px) { .grid2 { grid-template-columns: 1fr; } }
    dl.kv { display: grid; grid-template-columns: 150px 1fr; gap: 0.35rem 0.85rem; margin: 0; }
    dl.kv dt { color: var(--muted); }
    dl.kv dd { margin: 0; word-break: break-word; }
    .empty { color: var(--muted); padding: 0.5rem 0; }
    .stack-actions { display: flex; flex-wrap: wrap; gap: 0.35rem; align-items: center; }
    .stack-actions form { margin: 0; }
    .inline-check { display: flex; align-items: center; gap: 0.4rem; margin-top: 0.6rem; color: var(--text); text-transform: none; letter-spacing: normal; font-size: 14px; }
    .inline-check input { width: auto; max-width: none; }
    .compact-table td, .compact-table th { font-size: 12px; }
    .login-wrap { min-height: 100vh; }
    .login-theme { display: flex; justify-content: flex-end; padding: 0.75rem 1rem; }
    .login-main { max-width: 400px; margin: 2rem auto 3rem; padding: 0 1rem; }
    .login-kicker { color: var(--muted); font-size: 12px; letter-spacing: 0.12em; text-transform: uppercase; margin: 0 0 0.35rem; }
    .login-foot { margin-top: 1rem; font-size: 13px; }
    .login-card button[type="submit"] { width: 100%; max-width: none; }

    /* ===== Theme A: CRT console ===== */
    [data-theme="crt"] {
      --bg: #0a120c;
      --card: #121f16;
      --titlebar: #0e1a12;
      --panel-hd: #1a3322;
      --panel-hd-text: #a8d4b0;
      --text: #c8e6c9;
      --muted: #6f9a78;
      --acc: #7dff9a;
      --line: #2a4a32;
      --line-hi: #3d6b48;
      --ok: #5dffa0;
      --warn: #e6c35c;
      --err: #ff7a7a;
      --input-bg: #0a100c;
      --code-bg: #0a100c;
      --btn-bg: #2f8f4e;
      --btn-fg: #041208;
      --btn-border: #4caf6a;
      --btn-danger-fg: #1a0505;
      --flash-ok-bg: #0f2a18;
      --flash-ok-fg: #a8e6c5;
      --flash-err-bg: #2a1212;
      --flash-err-fg: #f0b4b4;
      --badge-ok-bg: #0f2a18;
      --badge-err-bg: #2a1212;
      --badge-warn-bg: #2a2410;
      --badge-muted-bg: #1a2a1e;
      --radius: 0;
      --radius-sm: 0;
      --font: "IBM Plex Mono", "ui-monospace", "Cascadia Mono", "SF Mono", Menlo, Consolas, monospace;
      --font-mono: var(--font);
    }
    [data-theme="crt"] body, body.admin-theme--crt {
      font: 13.5px/1.45 var(--font);
      background: var(--bg);
      color: var(--text);
    }
    body.admin-theme--crt::before {
      content: "";
      pointer-events: none;
      position: fixed; inset: 0; z-index: 9999;
      background: repeating-linear-gradient(
        to bottom,
        transparent 0, transparent 2px,
        rgba(0,0,0,0.08) 2px, rgba(0,0,0,0.08) 3px
      );
      opacity: 0.35;
    }
    @media (prefers-reduced-motion: reduce) {
      body.admin-theme--crt::before { display: none; }
    }
    [data-theme="crt"] .theme-link.active {
      background: var(--acc) !important; color: #041208 !important; border-color: var(--acc) !important;
    }
    [data-theme="crt"] .theme-link:not(.active) {
      background: transparent !important; color: var(--muted) !important; border-color: var(--line) !important;
    }

    /* ===== Theme C: paper / warm print ===== */
    [data-theme="paper"] {
      --bg: #f3e6c8;
      --card: #fff8e8;
      --titlebar: #e8d4a8;
      --panel-hd: #c44b3c;
      --panel-hd-text: #fff8e8;
      --text: #2a2118;
      --muted: #6b5a48;
      --acc: #8b1e1e;
      --line: #c9b896;
      --line-hi: #a89068;
      --ok: #2f6b3a;
      --warn: #9a6b12;
      --err: #a32020;
      --input-bg: #fffdf6;
      --code-bg: #efe2c4;
      --btn-bg: #8b1e1e;
      --btn-fg: #fff8e8;
      --btn-border: #6e1515;
      --btn-danger-fg: #fff8e8;
      --flash-ok-bg: #e5f0e2;
      --flash-ok-fg: #1e4a28;
      --flash-err-bg: #f5e0dc;
      --flash-err-fg: #6e1515;
      --badge-ok-bg: #e5f0e2;
      --badge-err-bg: #f5e0dc;
      --badge-warn-bg: #f5ebcf;
      --badge-muted-bg: #ebe0c8;
      --radius: 2px;
      --radius-sm: 2px;
      --font: "Iowan Old Style", "Palatino Linotype", Palatino, "Book Antiqua", Georgia, serif;
      --font-mono: "ui-monospace", "SF Mono", Menlo, Consolas, monospace;
    }
    [data-theme="paper"] body, body.admin-theme--paper {
      font: 15px/1.55 var(--font);
      background:
        radial-gradient(ellipse at 20% 0%, rgba(255,255,255,0.45), transparent 50%),
        var(--bg);
      color: var(--text);
    }
    [data-theme="paper"] .brand { letter-spacing: 0.04em; color: #5a1810; }
    [data-theme="paper"] .topbar { border-bottom-width: 3px; border-bottom-color: #8b1e1e; }
    [data-theme="paper"] h1 { font-weight: 600; color: #3a2218; }
    [data-theme="paper"] table { font-size: 14px; }
    [data-theme="paper"] code, [data-theme="paper"] textarea {
      font-family: var(--font-mono);
    }
    [data-theme="paper"] .theme-link.active {
      background: var(--acc) !important; color: #fff8e8 !important; border-color: var(--acc) !important;
    }
    [data-theme="paper"] .theme-link:not(.active) {
      background: transparent !important; color: var(--muted) !important; border-color: var(--line-hi) !important;
    }
    [data-theme="paper"] .card {
      box-shadow: 2px 2px 0 rgba(80, 50, 20, 0.08);
    }
    """
  end
end
