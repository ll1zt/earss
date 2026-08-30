defmodule Earss.Admin.HTML do
  @moduledoc false

  def layout(title, flash, body, head_extra \\ "") do
    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="utf-8"/>
      <meta name="viewport" content="width=device-width, initial-scale=1"/>
      <title>#{h(title)} · Earss Admin</title>
      #{head_extra}
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
    String.replace(
      html,
      "<!--FLASH-->",
      ~s(<div class="flash #{type}" role="status">#{h(msg)}</div>),
      global: false
    )
  end

  def shell(user, flash, title, inner, opts \\ []) do
    active = Keyword.get(opts, :active, "")

    head_extra =
      if refresh = Keyword.get(opts, :meta_refresh),
        do: ~s(<meta http-equiv="refresh" content="#{refresh}"/>),
        else: ""

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
        #{if Earss.TTS.configured?(), do: nav_link.("/admin/tts", "Listen", "tts")}
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

    layout(title, flash, nav, head_extra)
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

  @doc """
  Relative time with the absolute UTC timestamp as a tooltip.

  Future timestamps (next_fetch_at) render as "in 5m"; past ones as
  "5m ago"; older than a week falls back to the absolute date.
  """
  def time_ago(nil), do: "—"

  def time_ago(%DateTime{} = dt) do
    secs = DateTime.diff(DateTime.utc_now(), dt)
    rel = relative(secs) || format_dt(dt)
    ~s(<span title="#{format_dt(dt)}">#{h(rel)}</span>)
  end

  def time_ago(other), do: format_dt(other)

  defp relative(secs) when secs >= 0 do
    cond do
      secs < 60 -> "just now"
      secs < 3_600 -> "#{div(secs, 60)}m ago"
      secs < 86_400 -> "#{div(secs, 3_600)}h ago"
      secs < 7 * 86_400 -> "#{div(secs, 86_400)}d ago"
      true -> nil
    end
  end

  defp relative(secs) do
    secs = -secs

    cond do
      secs < 60 -> "in <1m"
      secs < 3_600 -> "in #{div(secs, 60)}m"
      secs < 86_400 -> "in #{div(secs, 3_600)}h"
      true -> "in #{div(secs, 86_400)}d"
    end
  end

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

  @doc "Translation-state badge for entry previews (pending / paused only)."
  def translation_badge(%{translation_pending_at: %DateTime{}, translation_paused_at: nil}),
    do: badge("translating", "warn")

  def translation_badge(%{translation_paused_at: %DateTime{}}), do: badge("paused", "err")
  def translation_badge(_), do: ""

  @doc """
  Prev/Next pagination footer preserving the current query params.

  `query` is the raw string-keyed params map (without `page`); the links
  keep filters/sort across page changes.
  """
  def pagination(path, page, total_pages, query \\ %{}) do
    link = fn p, label ->
      qs = query |> Map.drop(["page"]) |> Map.put("page", to_string(p)) |> URI.encode_query()
      ~s(<a class="btn secondary" href="#{h(path)}?#{qs}">#{label}</a>)
    end

    prev =
      if page > 1 do
        link.(page - 1, "‹ Prev")
      else
        ~s(<span class="btn secondary" style="opacity:.5">‹ Prev</span>)
      end

    next =
      if page < total_pages do
        link.(page + 1, "Next ›")
      else
        ~s(<span class="btn secondary" style="opacity:.5">Next ›</span>)
      end

    ~s(<div class="pagination">#{prev}<span class="muted">Page #{page} / #{total_pages}</span>#{next}</div>)
  end
end
