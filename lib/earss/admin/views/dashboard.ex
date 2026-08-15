defmodule Earss.Admin.Views.Dashboard do
  @moduledoc false

  alias Earss.Admin.HTML
  alias Earss.Admin.Helpers

  def page(user, flash, assigns) do
    %{
      subs: subs,
      cats: cats,
      unread: unread,
      problem_subs: problem_subs,
      due_subs: due_subs,
      recent: recent,
      telemetry: telemetry,
      fever_url: fever_url,
      greader_url: greader_url
    } = assigns

    problem_rows =
      problem_subs
      |> Enum.take(8)
      |> Enum.map(fn s ->
        f = s.feed
        title = Helpers.display_title(s)

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
        title = Helpers.display_title(s)

        """
        <tr>
          <td><a href="/admin/subscriptions/#{s.id}">#{HTML.h(title)}</a>
            <div class="muted">next: #{HTML.time_ago(f.next_fetch_at)}</div>
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

    recent_rows =
      Enum.map(recent, fn e ->
        feed_title = (e.feed && (e.feed.title || e.feed.link)) || "—"

        """
        <tr>
          <td>
            <a href="#{HTML.h(e.link)}" target="_blank" rel="noopener">#{HTML.h(e.title || e.link)}</a>
            #{HTML.translation_badge(e)}
            <div class="muted">#{HTML.h(feed_title)} · #{HTML.time_ago(e.published_at)}</div>
          </td>
        </tr>
        """
      end)
      |> Enum.join("\n")

    recent_block =
      if recent_rows == "" do
        ~s(<p class="empty">Nothing fetched yet — subscribe to a feed.</p>)
      else
        """
        <table class="compact-table">
          <tbody>#{recent_rows}</tbody>
        </table>
        """
      end

    health_block = fetch_health(telemetry)

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
        <h2>Recent entries <a class="muted" href="/admin/export/all?format=markdown" style="font-size:12px;font-weight:500">export all</a></h2>
        #{recent_block}
      </div>
      <div class="card">
        <h2>Fetch health <a class="muted" href="/admin/metrics" style="font-size:12px;font-weight:500">metrics</a></h2>
        #{health_block}
      </div>
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
      <p><strong>Fever</strong> URL: <code>#{HTML.h(fever_url)}</code> <button type="button" class="secondary" data-copy="#{HTML.h(fever_url)}">Copy</button></p>
      <p><strong>FreshRSS / GReader</strong> URL: <code>#{HTML.h(greader_url)}</code> <button type="button" class="secondary" data-copy="#{HTML.h(greader_url)}">Copy</button></p>
      <p class="muted">Username: <code>#{HTML.h(user.username)}</code> — password is login password or Fever-only secret (Settings).</p>
      <p class="muted">This admin manages sources; reading is in NNW.</p>
    </div>
    """

    HTML.shell(user, flash, "Dashboard", inner, active: "dashboard")
  end

  # Fetch health summary straight from the in-memory telemetry store
  # (since boot; resets with the app).
  defp fetch_health(telemetry) do
    fetch_counters = telemetry.counters[Earss.Telemetry.event_feed_fetch()] || %{}
    fetch_latency = telemetry.latency[Earss.Telemetry.event_feed_fetch()]
    total = fetch_counters |> Map.values() |> Enum.sum()

    failed =
      Enum.reduce(fetch_counters, 0, fn {k, n}, acc ->
        if k in [:http_error, :parse_error, :adapter_error, :error], do: acc + n, else: acc
      end)

    latency =
      case fetch_latency do
        %{count: c, sum: s} when c > 0 ->
          div(s, c) |> System.convert_time_unit(:native, :millisecond) |> then(&"#{&1} ms")

        _ ->
          "—"
      end

    last_failure =
      case List.first(telemetry.failures) do
        nil -> "none since boot"
        f -> HTML.time_ago(f.at)
      end

    """
    <dl class="kv">
      <dt>Fetches</dt><dd>#{total}</dd>
      <dt>Failed</dt><dd>#{failed}</dd>
      <dt>Avg latency</dt><dd>#{latency}</dd>
      <dt>Last failure</dt><dd>#{last_failure}</dd>
    </dl>
    <p class="muted" style="margin-top:.5rem">In-memory since app start.</p>
    """
  end
end
