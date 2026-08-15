defmodule Earss.Admin.Views.Feeds do
  @moduledoc false

  alias Earss.Admin.HTML
  alias Earss.Admin.Helpers
  alias Earss.FeedScheduler

  def index(user, flash, assigns) do
    %{
      subs: subs,
      all_count: all_count,
      status: status,
      q: q,
      sort: sort,
      page: page,
      total_pages: total_pages,
      now: now
    } = assigns

    status_opts =
      Helpers.option_list(
        [
          {"all", "All"},
          {"active", "Active"},
          {"disabled", "Disabled"},
          {"error", "Error"},
          {"due", "Due now"}
        ],
        status
      )

    sort_opts =
      Helpers.option_list(
        [
          {"title", "Title"},
          {"next_fetch", "Next fetch"},
          {"error_count", "Errors"},
          {"last_fetched", "Last fetch"}
        ],
        sort
      )

    rows =
      Enum.map(subs, fn s ->
        f = s.feed
        title = Helpers.display_title(s)
        due_cls = HTML.due_class(f.next_fetch_at, now)

        """
        <tr>
          <td>
            <label class="inline-check" style="margin:0">
              <input type="checkbox" name="ids[]" value="#{f.id}" form="batch-feeds" aria-label="Select #{HTML.h(title)}"/>
              <span>
                <a href="/admin/subscriptions/#{s.id}"><strong>#{HTML.h(title)}</strong></a>
                <div class="muted">#{HTML.h(f.link)}</div>
                #{if f.last_error, do: ~s(<div class="err-text">#{HTML.h(f.last_error)}</div>), else: ""}
              </span>
            </label>
          </td>
          <td>#{HTML.feed_status_badge(f)}</td>
          <td>#{f.error_count}</td>
          <td class="muted">#{HTML.time_ago(f.last_fetched_at)}</td>
          <td class="#{due_cls}">#{HTML.time_ago(f.next_fetch_at)}</td>
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
      cond do
        rows != "" ->
          rows

        all_count == 0 ->
          ~s(<tr><td colspan="8" class="empty">No feeds yet — subscribe from <a href="/admin/subscriptions">Subscriptions</a>.</td></tr>)

        true ->
          ~s(<tr><td colspan="8" class="empty">No feeds match the filters. <a href="/admin/feeds">Reset filters</a></td></tr>)
      end

    inner = """
    <div class="card">
      <p class="muted">Feeds you subscribe to. Refresh runs a single fetch; re-enable clears the error circuit-breaker; disable stops scheduling.</p>
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
          <label>Sort</label>
          <select name="sort">#{sort_opts}</select>
        </div>
        <div class="field">
          <button type="submit">Filter</button>
          <a class="btn secondary" href="/admin/feeds">Reset</a>
        </div>
      </form>
      <p class="muted">Showing #{Helpers.showing_range(page, all_count)} / #{all_count}</p>
      <form id="batch-feeds" method="post" action="/admin/feeds/batch" class="stack-actions" style="margin:.75rem 0">#{HTML.csrf_input()}
        <select name="action" aria-label="Batch action">
          <option value="refresh">Refresh</option>
          <option value="reenable">Re-enable</option>
          <option value="disable">Disable</option>
        </select>
        <button type="submit">Apply to selected</button>
        <span class="muted">Select rows below (max #{Earss.Admin.Batch.limit()})</span>
      </form>
      <table class="compact-table">
        <thead>
          <tr>
            <th><input type="checkbox" data-select-all="ids[]" aria-label="Select all on page"/></th>
            <th>Feed</th><th>Status</th><th>Errors</th><th>Last fetch</th><th>Next</th><th>Interval</th><th></th>
          </tr>
        </thead>
        <tbody>#{empty}</tbody>
      </table>
      #{HTML.pagination("/admin/feeds", page, total_pages, %{"q" => q, "status" => status, "sort" => sort})}
    </div>
    """

    HTML.shell(user, flash, "Feeds", inner, active: "feeds")
  end
end
