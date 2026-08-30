defmodule Earss.Admin.Views.TTS do
  @moduledoc false

  alias Earss.Admin.HTML
  alias Earss.Admin.Helpers

  @states ~w(requested processing ready failed)

  def index(user, flash, assigns) do
    %{stats: stats, providers: providers, requests: requests, state: state} = assigns
    tts_cfg = assigns[:tts_cfg]

    inner = """
    <div class="card">
      <h2>Listening queue</h2>
      <div class="row">
        <div class="stat"><div class="muted">Ready</div><div class="n">#{stats.ready}</div></div>
        <div class="stat"><div class="muted">Requested</div><div class="n">#{stats.requested}</div></div>
        <div class="stat"><div class="muted">Processing</div><div class="n">#{stats.processing}</div></div>
        <div class="stat">
          <div class="muted">Failed</div>
          <div class="n #{if stats.failed > 0, do: "warn"}">#{stats.failed}</div>
        </div>
        <div class="stat"><div class="muted">Audio on disk</div><div class="n">#{format_bytes(stats.audio_bytes)}</div></div>
      </div>
    </div>
    <div class="card">
      <h2>Provider &amp; worker</h2>
      #{provider_block(providers, tts_cfg)}
    </div>
    <div class="card">
      <h2>Podcast feed</h2>
      #{podcast_block(tts_cfg, stats)}
    </div>
    <div class="card">
      <h2>Requests (most recent first)</h2>
      #{state_tabs(state)}
      <table>
        <thead>
          <tr>
            <th><input type="checkbox" data-select-all="ids[]" aria-label="Select all on page"/></th>
            <th>Entry</th><th>State</th><th>Provider</th><th>Size</th><th>Duration</th><th>Updated</th><th>Error</th><th></th>
          </tr>
        </thead>
        <tbody>#{request_rows(requests)}</tbody>
      </table>
      <form id="batch-tts" method="post" action="/admin/tts/batch" class="stack-actions" style="margin:.75rem 0">#{HTML.csrf_input()}
        <select name="action" aria-label="Batch action">
          <option value="requeue">Retry selected</option>
          <option value="delete">Delete selected</option>
        </select>
        <button type="submit" data-confirm-select="action" data-confirm-value="delete" data-confirm-msg="Delete the selected requests and their audio? Entries can be re-requested later.">Apply to selected</button>
        <span class="muted">Select rows above (max #{Earss.Admin.Batch.limit()})</span>
      </form>
    </div>
    """

    HTML.shell(user, flash, "Listen", inner, active: "tts")
  end

  # —— sections ——

  defp provider_block([], _tts_cfg) do
    ~s{<p class="err-text">No TTS provider loaded.</p>} <>
      ~s{<p class="muted">Install one (e.g. <code>earss_tts_podcast</code>) via } <>
      ~s{<code>EARSS_TTS_PLUGINS</code> in <code>earss.env</code> and restart. } <>
      ~s{Requested rows wait until a provider is available.} <>
      ~s{ See <a href="/admin/settings">Settings</a> for the env keys.}
  end

  defp provider_block(providers, tts_cfg) do
    rows =
      Enum.map_join(providers, "\n", fn p ->
        """
        <tr>
          <td><code>#{HTML.h(p.id)}</code></td>
          <td>#{HTML.h(inspect(p.module))}</td>
          <td>#{HTML.h(p.version || "—")}</td>
        </tr>
        """
      end)

    worker = Keyword.get(tts_cfg, :worker, [])
    on? = Keyword.get(worker, :enabled, false)
    dir = Keyword.get(tts_cfg, :audio_dir)

    config_lines =
      [
        "worker #{Helpers.on_off(on?)} · every #{Helpers.format_interval_ms(Keyword.get(worker, :interval_ms, 30_000))} · batch #{Keyword.get(worker, :batch_size, 5)} · retries #{Keyword.get(worker, :max_retries, 5)}",
        "audio_dir #{if is_binary(dir), do: HTML.h(dir), else: "not set"}",
        "audio expiry #{tts_expiry_label()} · listen controls #{Helpers.on_off(Keyword.get(tts_cfg, :listen_controls, false))}"
      ]
      |> Enum.map_join("\n", &~s(<p class="muted" style="margin:.35rem 0 0">#{&1}</p>))

    warnings =
      if on? do
        cond do
          is_nil(dir) ->
            warn(
              "Worker is enabled but audio_dir is not set — it will idle until one is configured."
            )

          providers == [] ->
            warn(
              "Worker is enabled but no provider is registered — requested rows wait until a plugin loads."
            )

          true ->
            ""
        end
      else
        ""
      end

    ~s(<table><thead><tr><th>id</th><th>module</th><th>version</th></tr></thead><tbody>#{rows}</tbody></table>) <>
      config_lines <>
      warnings
  end

  defp podcast_block(tts_cfg, stats) do
    public_url = Keyword.get(tts_cfg, :public_url)

    feed_url =
      if is_binary(public_url) and public_url != "",
        do: "#{String.trim_trailing(public_url, "/")}/podcast/rss.xml",
        else: nil

    base =
      cond do
        is_binary(feed_url) ->
          ~s(<p><code>#{HTML.h(feed_url)}</code></p>)

        stats.ready > 0 ->
          warn(
            "No public_url configured — the feed cannot advertise enclosure URLs. Set EARSS_TTS_PUBLIC_URL."
          )

          ""

        true ->
          ""
      end

    scheme_warn =
      if (feed_url && String.starts_with?(feed_url, "http://")) and stats.ready > 0 do
        warn("Plain-HTTP media: Apple Podcasts silently fails to play it (see docs/tts.md).")
      else
        ""
      end

    cover =
      if Keyword.get(tts_cfg, :podcast, []) |> Keyword.get(:cover_path),
        do: "configured",
        else: "not configured"

    base <>
      scheme_warn <>
      "<p class=\"muted\" style=\"margin:.35rem 0 0\">cover: #{cover} · unauthenticated by design (podcast clients cannot log in) · Apple Podcasts requires HTTPS.</p>"
  end

  # —— table ——

  defp state_tabs(current) do
    tabs =
      Enum.map_join(["all" | @states], " · ", fn s ->
        label = if s == "all", do: "all", else: s
        path = if s == "all", do: "/admin/tts", else: "/admin/tts?state=#{s}"

        if s == current do
          ~s(<b>#{label}</b>)
        else
          ~s(<a href="#{path}">#{label}</a>)
        end
      end)

    ~s(<p class="muted" style="margin:.25rem 0 .5rem">#{tabs}</p>)
  end

  defp request_rows([]) do
    ~s(<tr><td colspan="9" class="empty">No requests.</td></tr>)
  end

  defp request_rows(requests) do
    Enum.map_join(requests, "\n", fn r ->
      entry = Map.get(r, :entry)

      {title, _link} =
        case entry do
          %{} = e ->
            title = e.title || "(untitled)"

            href =
              if e.link,
                do:
                  ~s(<a href="#{HTML.h(e.link)}" target="_blank" rel="noopener">#{HTML.h(title)} ↗</a>),
                else: HTML.h(title)

            {href, e.link}

          nil ->
            {"entry ##{r.entry_id}", nil}
        end

      error =
        case r.error do
          nil -> "—"
          msg -> ~s(<span title="#{HTML.h(msg)}">#{HTML.h(truncate(msg, 60))}</span>)
        end

      actions =
        cond do
          r.state in [:requested, :failed] ->
            row_action(r.id, "requeue", "Retry")

          r.state == :ready ->
            row_action(r.id, "delete", "Delete")

          true ->
            ""
        end

      """
      <tr>
        <td><input type="checkbox" name="ids[]" value="#{r.id}" form="batch-tts" aria-label="Select #{HTML.h(r.entry_id)}"/></td>
        <td>#{title}</td>
        <td><span class="#{state_class(r.state)}">#{r.state}</span></td>
        <td>#{HTML.h(r.provider || "—")}</td>
        <td>#{format_bytes(r.audio_bytes)}</td>
        <td>#{Earss.TTS.Audio.format_duration(r.audio_duration_secs)}</td>
        <td>#{HTML.time_ago(r.updated_at)}</td>
        <td>#{error}</td>
        <td>#{actions}</td>
      </tr>
      """
    end)
  end

  defp row_action(id, action, label) do
    ~s(<form method="post" action="/admin/tts/#{id}/#{action}" style="display:inline">) <>
      HTML.csrf_input() <>
      ~s(<button type="submit" class="secondary" data-confirm="#{label} this request?">#{label}</button></form>)
  end

  defp state_class(:ready), do: "muted"
  defp state_class(:failed), do: "err-text"
  defp state_class(:processing), do: "warn"
  defp state_class(_), do: ""

  # —— helpers ——

  defp tts_expiry_label do
    days = Application.get_env(:earss, :retention, []) |> Keyword.get(:tts_audio_days)

    if days == nil, do: "off", else: "#{days} d"
  end

  defp warn(msg) do
    ~s(<p class="warn-text" style="margin:.35rem 0 0">⚠ #{HTML.h(msg)}</p>)
  end

  defp truncate(msg, len) when byte_size(msg) <= len, do: msg

  defp truncate(msg, len) do
    String.slice(msg, 0, len) <> "…"
  end

  defp format_bytes(nil), do: "—"
  defp format_bytes(0), do: "0 B"

  defp format_bytes(bytes) when is_integer(bytes) and bytes > 0 do
    {value, unit} = human_bytes(bytes * 1.0, "B")
    "#{:erlang.float_to_binary(value, decimals: 1)} #{unit}"
  end

  defp human_bytes(n, unit) when n < 1024 or unit == "TB", do: {n, unit}
  defp human_bytes(n, "B"), do: human_bytes(n / 1024, "KB")
  defp human_bytes(n, "KB"), do: human_bytes(n / 1024, "MB")
  defp human_bytes(n, "MB"), do: human_bytes(n / 1024, "GB")
  defp human_bytes(n, "GB"), do: human_bytes(n / 1024, "TB")
end
