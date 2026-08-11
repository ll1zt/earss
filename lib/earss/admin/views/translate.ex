defmodule Earss.Admin.Views.Translate do
  @moduledoc false

  alias Earss.Admin.HTML
  alias Earss.Admin.Helpers

  def index(user, flash, assigns) do
    %{translators: translators, enabled_feeds: enabled_feeds, enabled_subs: enabled_subs} =
      assigns

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
            "#{HTML.h(lang)} #{n}/#{s.total}"
          end)

        """
        <tr>
          <td><a href="/admin/subscriptions?q=#{HTML.h(f.link)}">#{HTML.h(f.title || f.link)}</a></td>
          <td><code>#{HTML.h(f.translate_to)}</code></td>
          <td>#{HTML.h(f.translate_from || "—")}</td>
          <td>#{counts}</td>
          <td>#{s.errors}</td>
        </tr>
        """
      end)
      |> Enum.join("\n")

    feed_empty =
      if feed_rows == "",
        do: ~s(<tr><td colspan="5" class="empty">No feeds with translation enabled.</td></tr>),
        else: feed_rows

    sub_rows =
      Enum.map(enabled_subs, fn s ->
        f = s.feed

        """
        <tr>
          <td><a href="/admin/subscriptions/#{s.id}">#{HTML.h(Helpers.display_title(s))}</a></td>
          <td><code>#{HTML.h(s.translate_to)}</code></td>
          <td>#{if(s.return_original, do: "yes", else: "no")}</td>
          <td>#{HTML.h((f && f.link) || "—")}</td>
        </tr>
        """
      end)
      |> Enum.join("\n")

    sub_empty =
      if sub_rows == "",
        do: ~s(<tr><td colspan="4" class="empty">No per-subscription overrides.</td></tr>),
        else: sub_rows

    inner = """
    <div class="card">
      <h2>Translation plugin</h2>
      #{plugin_block}
      <p class="muted" style="margin-top:.75rem">Feed-level configuration applies to all readers; per-subscription overrides apply to one account (and can append the original text).</p>
    </div>
    <div class="card">
      <h2>Feeds with translation enabled (#{length(enabled_feeds)})</h2>
      <table>
        <thead><tr><th>Feed</th><th>To</th><th>From</th><th>Translated</th><th>Errors</th></tr></thead>
        <tbody>#{feed_empty}</tbody>
      </table>
    </div>
    <div class="card">
      <h2>Subscription overrides (#{length(enabled_subs)})</h2>
      <table>
        <thead><tr><th>Subscription</th><th>To</th><th>Append original</th><th>Feed</th></tr></thead>
        <tbody>#{sub_empty}</tbody>
      </table>
    </div>
    """

    HTML.shell(user, flash, "Translate", inner, active: "translate")
  end
end
