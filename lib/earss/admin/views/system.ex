defmodule Earss.Admin.Views.System do
  @moduledoc false

  alias Earss.Admin.HTML
  alias Earss.Admin.Helpers

  def page(user, flash, assigns) do
    %{
      due: due,
      due_total: due_total,
      disabled: disabled,
      errors: errors,
      refresh: refresh,
      retention: retention,
      poller: poller,
      ret_poller: ret_poller,
      api: api
    } = assigns

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
          <dt>Poller</dt><dd>#{Helpers.on_off(Keyword.get(poller, :enabled, true))} · every #{Keyword.get(poller, :interval_ms)} ms · batch #{Keyword.get(poller, :batch_size)}</dd>
          <dt>Retention poller</dt><dd>#{Helpers.on_off(Keyword.get(ret_poller, :enabled, true))} · every #{Keyword.get(ret_poller, :interval_ms)} ms</dd>
          <dt>API</dt><dd>#{Helpers.on_off(Keyword.get(api, :enabled, true))} · port #{Keyword.get(api, :port)}</dd>
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

    HTML.shell(user, flash, "System", inner, active: "system")
  end
end
