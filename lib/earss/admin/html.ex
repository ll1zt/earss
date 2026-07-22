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
        :root { --bg:#0f1419; --card:#1a2332; --text:#e7ecf3; --muted:#8b9bb4; --acc:#5b9fd4; --ok:#3d9a6a; --err:#c45c5c; --line:#2a3548; }
        * { box-sizing: border-box; }
        body { margin:0; font:15px/1.5 system-ui,sans-serif; background:var(--bg); color:var(--text); }
        a { color:var(--acc); text-decoration:none; }
        a:hover { text-decoration:underline; }
        header { background:var(--card); border-bottom:1px solid var(--line); padding:.75rem 1.25rem; display:flex; gap:1rem; align-items:center; flex-wrap:wrap; }
        header .brand { font-weight:700; color:#fff; margin-right:.5rem; }
        header nav a { margin-right:.9rem; color:var(--muted); }
        header nav a:hover { color:var(--text); }
        main { max-width:960px; margin:1.25rem auto; padding:0 1rem 3rem; }
        .card { background:var(--card); border:1px solid var(--line); border-radius:10px; padding:1rem 1.15rem; margin-bottom:1rem; }
        h1 { font-size:1.35rem; margin:0 0 1rem; }
        h2 { font-size:1.05rem; margin:0 0 .75rem; color:var(--muted); font-weight:600; }
        table { width:100%; border-collapse:collapse; font-size:14px; }
        th, td { text-align:left; padding:.45rem .35rem; border-bottom:1px solid var(--line); vertical-align:top; }
        th { color:var(--muted); font-weight:600; }
        .muted { color:var(--muted); }
        .flash { padding:.65rem .85rem; border-radius:8px; margin-bottom:1rem; }
        .flash.ok { background:#1a3d2c; color:#a8e6c5; }
        .flash.err { background:#3d1a1a; color:#f0b4b4; }
        label { display:block; margin:.4rem 0 .2rem; color:var(--muted); font-size:13px; }
        input, select, textarea { width:100%; max-width:420px; padding:.45rem .55rem; border-radius:6px; border:1px solid var(--line); background:#0d1218; color:var(--text); }
        textarea { min-height:120px; max-width:100%; font-family:ui-monospace,monospace; font-size:13px; }
        button, .btn { display:inline-block; margin-top:.5rem; margin-right:.4rem; padding:.4rem .75rem; border-radius:6px; border:1px solid var(--line); background:var(--acc); color:#061018; font-weight:600; cursor:pointer; font-size:13px; }
        button.secondary, .btn.secondary { background:transparent; color:var(--text); }
        button.danger { background:var(--err); color:#fff; border-color:transparent; }
        .row { display:flex; flex-wrap:wrap; gap:1rem; }
        .stat { flex:1; min-width:120px; }
        .stat .n { font-size:1.6rem; font-weight:700; }
        .err-text { color:#f0b4b4; font-size:12px; }
        code { background:#0d1218; padding:.1rem .3rem; border-radius:4px; font-size:12px; }
        .actions form { display:inline; }
        .actions button { margin-top:0; }
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

  def shell(user, flash, title, inner) do
    nav = """
    <header>
      <span class="brand">Earss</span>
      <nav>
        <a href="/admin">Dashboard</a>
        <a href="/admin/subscriptions">Subscriptions</a>
        <a href="/admin/categories">Categories</a>
        <a href="/admin/feeds">Feeds</a>
        <a href="/admin/opml">OPML</a>
        <a href="/admin/settings">Settings</a>
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
end
