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
      <style>
        :root { --bg:#0f1419; --card:#1a2332; --text:#e7ecf3; --muted:#8b9bb4; --acc:#5b9fd4; --ok:#3d9a6a; --err:#c45c5c; --line:#2a3548; --warn:#c4a35c; }
        * { box-sizing: border-box; }
        body { margin:0; font:15px/1.5 system-ui,sans-serif; background:var(--bg); color:var(--text); }
        a { color:var(--acc); text-decoration:none; }
        a:hover { text-decoration:underline; }
        header { background:var(--card); border-bottom:1px solid var(--line); padding:.75rem 1.25rem; display:flex; gap:1rem; align-items:center; flex-wrap:wrap; }
        header .brand { font-weight:700; color:#fff; margin-right:.5rem; }
        header nav a { margin-right:.9rem; color:var(--muted); }
        header nav a:hover, header nav a.active { color:var(--text); }
        header nav a.active { font-weight:600; }
        main { max-width:1100px; margin:1.25rem auto; padding:0 1rem 3rem; }
        .card { background:var(--card); border:1px solid var(--line); border-radius:10px; padding:1rem 1.15rem; margin-bottom:1rem; }
        h1 { font-size:1.35rem; margin:0 0 1rem; }
        h2 { font-size:1.05rem; margin:0 0 .75rem; color:var(--muted); font-weight:600; }
        table { width:100%; border-collapse:collapse; font-size:14px; }
        th, td { text-align:left; padding:.45rem .35rem; border-bottom:1px solid var(--line); vertical-align:top; }
        th { color:var(--muted); font-weight:600; white-space:nowrap; }
        .muted { color:var(--muted); }
        .flash { padding:.65rem .85rem; border-radius:8px; margin-bottom:1rem; }
        .flash.ok { background:#1a3d2c; color:#a8e6c5; }
        .flash.err { background:#3d1a1a; color:#f0b4b4; }
        label { display:block; margin:.4rem 0 .2rem; color:var(--muted); font-size:13px; }
        input, select, textarea { width:100%; max-width:420px; padding:.45rem .55rem; border-radius:6px; border:1px solid var(--line); background:#0d1218; color:var(--text); }
        textarea { min-height:120px; max-width:100%; font-family:ui-monospace,monospace; font-size:13px; }
        button, .btn { display:inline-block; margin-top:.5rem; margin-right:.4rem; padding:.4rem .75rem; border-radius:6px; border:1px solid var(--line); background:var(--acc); color:#061018; font-weight:600; cursor:pointer; font-size:13px; text-decoration:none; }
        a.btn:hover { text-decoration:none; opacity:.92; }
        button.secondary, .btn.secondary { background:transparent; color:var(--text); }
        button.danger { background:var(--err); color:#fff; border-color:transparent; }
        .row { display:flex; flex-wrap:wrap; gap:1rem; }
        .stat { flex:1; min-width:120px; }
        .stat a { color:inherit; text-decoration:none; display:block; }
        .stat a:hover .n { color:var(--acc); }
        .stat .n { font-size:1.6rem; font-weight:700; }
        .err-text { color:#f0b4b4; font-size:12px; }
        .warn-text { color:#e6d5a8; font-size:12px; }
        code { background:#0d1218; padding:.1rem .3rem; border-radius:4px; font-size:12px; }
        .actions form { display:inline; }
        .actions button, .actions .btn { margin-top:0; }
        .filters { display:flex; flex-wrap:wrap; gap:.65rem 1rem; align-items:flex-end; margin-bottom:.25rem; }
        .filters .field { min-width:120px; }
        .filters input, .filters select { max-width:220px; margin:0; }
        .filters button { margin-top:0; }
        .badge { display:inline-block; padding:.1rem .45rem; border-radius:999px; font-size:11px; font-weight:600; line-height:1.4; }
        .badge.ok { background:#1a3d2c; color:#a8e6c5; }
        .badge.err { background:#3d1a1a; color:#f0b4b4; }
        .badge.warn { background:#3d351a; color:#e6d5a8; }
        .badge.muted { background:#243044; color:var(--muted); }
        .grid2 { display:grid; grid-template-columns:1fr 1fr; gap:1rem; }
        @media (max-width:800px) { .grid2 { grid-template-columns:1fr; } }
        dl.kv { display:grid; grid-template-columns:150px 1fr; gap:.35rem .85rem; margin:0; }
        dl.kv dt { color:var(--muted); }
        dl.kv dd { margin:0; word-break:break-word; }
        .empty { color:var(--muted); padding:.5rem 0; }
        .stack-actions { display:flex; flex-wrap:wrap; gap:.35rem; align-items:center; }
        .stack-actions form { margin:0; }
        .inline-check { display:flex; align-items:center; gap:.4rem; margin-top:.6rem; color:var(--text); }
        .inline-check input { width:auto; max-width:none; }
        .compact-table td, .compact-table th { font-size:13px; }
      </style>
    </head>
    <body>
      #{body}
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
    <header>
      <span class="brand">Earss</span>
      <nav>
        #{nav_link.("/admin", "Dashboard", "dashboard")}
        #{nav_link.("/admin/subscriptions", "Subscriptions", "subscriptions")}
        #{nav_link.("/admin/categories", "Categories", "categories")}
        #{nav_link.("/admin/feeds", "Feeds", "feeds")}
        #{nav_link.("/admin/system", "System", "system")}
        #{nav_link.("/admin/opml", "OPML", "opml")}
        #{nav_link.("/admin/settings", "Settings", "settings")}
      </nav>
      <span class="muted" style="margin-left:auto">#{h(user.username)}</span>
      <form method="post" action="/admin/logout" style="margin:0">
        <button type="submit" class="secondary">Log out</button>
      </form>
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
    <main style="max-width:400px;margin-top:4rem">
      <div class="card">
        <h1>Admin login</h1>
        #{err}
        <form method="post" action="/admin/login">
          <label>Username</label>
          <input name="username" autocomplete="username" required/>
          <label>Password</label>
          <input name="password" type="password" autocomplete="current-password" required/>
          <button type="submit">Sign in</button>
        </form>
      </div>
      <p class="muted" style="margin-top:1rem;font-size:13px">Reading: NetNewsWire via <a href="/fever/">Fever</a> or FreshRSS/GReader <code>/api/greader.php</code>.</p>
    </main>
    """

    layout("Login", flash, body)
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
