defmodule Earss.Admin.Views.Translate do
  @moduledoc false

  alias Earss.Admin.HTML

  def index(user, flash, assigns) do
    %{translators: translators, enabled_feeds: enabled_feeds} = assigns

    plugin_block =
      if translators == [] do
        ~s{<p class="err-text">No translation plugin loaded.</p>} <>
          ~s{<p class="muted">Install one (e.g. <code>earss_translate_openai</code>) via } <>
          ~s{<code>EARSS_TRANSLATE_PLUGINS</code> in <code>earss.env</code>, restart, then } <>
          ~s{configure feeds from the Subscriptions page.</p>}
      else
        rows =
          Enum.map(translators, fn t ->
            """
            <tr>
              <td><code>#{HTML.h(t.id)}</code></td>
              <td>#{HTML.h(inspect(t.module))}</td>
              <td>#{HTML.h(t.version || "—")}</td>
            </tr>
            """
          end)
          |> Enum.join("\n")

        ~s(<table><thead><tr><th>id</th><th>module</th><th>version</th></tr></thead>) <>
          ~s(<tbody>#{rows}</tbody></table>)
      end

    feed_rows =
      Enum.map(enabled_feeds, fn f ->
        s = f.stats

        counts =
          Enum.map_join(s.languages, " · ", fn {lang, n} ->
            "#{HTML.h(lang)} #{n}/#{s.need}"
          end)

        status =
          cond do
            s.paused > 0 ->
              "#{s.pending} processing · <b class=\"warn\">#{s.paused} paused</b>"

            s.pending > 0 ->
              "#{s.pending} processing"

            true ->
              "caught up"
          end

        actions =
          if s.pending > 0 or s.paused > 0 do
            sub_id = Map.get(f, :first_sub_id, "")

            ~s(<form method="post" action="/admin/subscriptions/#{sub_id}/retry_translations" style="display:inline">) <>
              HTML.csrf_input() <>
              ~s(<button type="submit">Re-translate</button></form> ) <>
              ~s(<form method="post" action="/admin/subscriptions/#{sub_id}/publish_translations" style="display:inline">) <>
              HTML.csrf_input() <>
              ~s(<button type="submit">Publish</button></form>)
          else
            ""
          end

        """
        <tr>
          <td>
            <input type="checkbox" name="ids[]" value="#{f.id}" form="batch-translate" aria-label="Select #{HTML.h(f.title || f.link)}"/>
          </td>
          <td><a href="/admin/subscriptions?q=#{HTML.h(f.link)}">#{HTML.h(f.title || f.link)}</a></td>
          <td><code>#{HTML.h(f.translate_to)}</code></td>
          <td>#{HTML.h(f.translate_from || "—")}</td>
          <td>#{counts}</td>
          <td>#{status}</td>
          <td>#{s.errors}</td>
          <td>#{actions}</td>
        </tr>
        """
      end)
      |> Enum.join("\n")

    feed_empty =
      if feed_rows == "",
        do: ~s(<tr><td colspan="8" class="empty">No feeds with translation enabled.</td></tr>),
        else: feed_rows

    inner = """
    <div class="card">
      <h2>Translation plugin</h2>
      #{plugin_block}
      <p class="muted" style="margin-top:.75rem">Feed-level configuration applies to every reader (single-operator mode).</p>
    </div>
    <div class="card">
      <h2>Feeds with translation enabled (#{length(enabled_feeds)})</h2>
      <table>
        <thead>
          <tr>
            <th><input type="checkbox" data-select-all="ids[]" aria-label="Select all on page"/></th>
            <th>Feed</th><th>To</th><th>From</th><th>Translated</th><th>Status</th><th>Errors</th><th>Actions</th>
          </tr>
        </thead>
        <tbody>#{feed_empty}</tbody>
      </table>
      <form id="batch-translate" method="post" action="/admin/translate/batch" class="stack-actions" style="margin:.75rem 0" data-confirm-select="action" data-confirm-value="publish" data-confirm-msg="Publish untranslated originals for the selected feeds?">#{HTML.csrf_input()}
        <select name="action" aria-label="Batch action">
          <option value="retry">Re-translate paused</option>
          <option value="publish">Publish originals</option>
        </select>
        <button type="submit">Apply to selected</button>
        <span class="muted">Select rows above (max #{Earss.Admin.Batch.limit()})</span>
      </form>
    </div>
    """

    HTML.shell(user, flash, "Translate", inner, active: "translate")
  end
end
