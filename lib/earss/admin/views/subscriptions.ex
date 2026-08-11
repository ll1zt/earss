defmodule Earss.Admin.Views.Subscriptions do
  @moduledoc false

  alias Earss.Admin.HTML
  alias Earss.Admin.Helpers
  alias Earss.FeedScheduler

  def index(user, flash, assigns) do
    %{
      filtered: filtered,
      subs: subs,
      q: q,
      category_id: category_id,
      status: status,
      sort: sort,
      cats: cats
    } = assigns

    cat_opts = Helpers.category_options(cats, nil)
    filter_cat_opts = Helpers.category_options(cats, category_id, include_all: true)

    rows =
      Enum.map(filtered, fn s ->
        title = Helpers.display_title(s)
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
      Helpers.option_list(
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
      Helpers.option_list(
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
      <p class="muted" style="margin-top:0.75rem">Plugin sources (<code>earss://…</code>): use
        <a href="/admin/sources">Sources</a> for adapter routes and wizards.</p>
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

    HTML.shell(user, flash, "Subscriptions", inner, active: "subscriptions")
  end

  def show(user, flash, sub, cats, now) do
    f = sub.feed
    title = Helpers.display_title(sub)
    effective = if f, do: FeedScheduler.effective_interval(f), else: nil
    cat_opts = Helpers.category_options(cats, sub.category_id && to_string(sub.category_id))
    hidden_checked = if sub.is_hidden, do: "checked", else: ""

    # Goal 2 translation stats (only when a target language is configured)
    tstats =
      if f && f.translate_to do
        s = Earss.Enrichment.stats(f)

        counts =
          Enum.map_join(s.languages, " · ", fn {lang, n} -> "#{HTML.h(lang)} #{n}/#{s.total}" end)

        "<dt>Translated</dt><dd>#{counts}</dd>" <>
          "<dt>Translation errors</dt><dd>#{s.errors}</dd>"
      else
        ""
      end

    interval_val =
      case sub.custom_refresh_interval do
        n when is_integer(n) -> to_string(n)
        _ -> ""
      end

    custom_title_val = sub.custom_title || ""

    # Goal 2 translation form values
    sub_translate_val = sub.translate_to || ""
    sub_layout_val = sub.original_layout || "inline"
    feed_translate_val = (f && f.translate_to) || ""
    feed_translate_from_val = (f && f.translate_from) || ""
    trans_err = (f && f.translate_error_count) || 0
    feed_layout_val = (f && f.original_layout) || "off"

    layout_opts = fn selected ->
      Helpers.option_list(
        [
          {"off", "Translation only"},
          {"inline", "Translation + original (inline)"},
          {"section", "Translation + original (section)"},
          {"interleaved", "Alternate paragraph by paragraph"}
        ],
        selected
      )
    end

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
            <dt>Source</dt><dd>#{HTML.h(Map.get(f, :source_kind) || "native")} · <code>#{HTML.h(Map.get(f, :adapter_id) || "native")}</code></dd>
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
            <dt>Adapter cursor</dt><dd class="muted"><code>#{HTML.h(inspect(Map.get(f, :adapter_cursor)))}</code></dd>
            #{tstats}
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
    #{translation_forms(sub, f, sub_translate_val, sub_layout_val, feed_translate_val, feed_translate_from_val, feed_layout_val, trans_err, layout_opts)}
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

    HTML.shell(user, flash, "Subscription · #{title}", inner, active: "subscriptions")
  end

  # Goal 2 translation forms render only when a translator plugin is loaded.
  defp translation_forms(
         sub,
         _f,
         sub_lang,
         sub_layout,
         feed_lang,
         feed_from,
         feed_layout,
         err,
         layout_opts
       ) do
    if Earss.Enrichment.enricher() != nil do
      """
      <div class="grid2">
        <div class="card">
          <h2>Subscription translation (you only)</h2>
          <form method="post" action="/admin/subscriptions/#{sub.id}/translation">#{HTML.csrf_input()}
            <label>Translate to (blank = follow feed)</label>
            <input name="translate_to" value="#{HTML.h(sub_lang)}" placeholder="e.g. zh"/>
            <label>Original text layout</label>
            <select name="original_layout">#{layout_opts.(sub_layout)}</select>
            <div><button type="submit">Save override</button></div>
          </form>
          <p class="muted">New entries are translated as they are fetched (hidden until ready); failed translations are retried automatically.</p>
        </div>
        <div class="card">
          <h2>Feed translation (shared by all subscribers)</h2>
          <form method="post" action="/admin/subscriptions/#{sub.id}/feed_translation">#{HTML.csrf_input()}
            <label>Translate to (blank = off)</label>
            <input name="feed_translate_to" value="#{HTML.h(feed_lang)}" placeholder="e.g. zh"/>
            <label>Source language (blank = auto-detect)</label>
            <input name="feed_translate_from" value="#{HTML.h(feed_from)}" placeholder="e.g. en"/>
            <label>Original text layout</label>
            <select name="feed_original_layout">#{layout_opts.(feed_layout)}</select>
            <div class="stack-actions" style="margin-top:.75rem">
              <button type="submit">Save feed setting</button>
            </div>
          </form>
          <p class="muted">Translation errors: #{err} · Existing entries stay in the original language; new entries are translated as they are fetched.</p>
        </div>
      </div>
      """
    else
      ""
    end
  end
end
