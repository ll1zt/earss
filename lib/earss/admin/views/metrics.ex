defmodule Earss.Admin.Views.Metrics do
  @moduledoc false

  alias Earss.Admin.HTML

  @fetch_outcomes [
    {:success, "Success"},
    {:not_modified, "Not modified"},
    {:http_error, "HTTP error"},
    {:parse_error, "Parse error"},
    {:adapter_error, "Adapter error"},
    {:error, "Other error"}
  ]

  @failure_labels %{
    http_error: "http error",
    parse_error: "parse error",
    adapter_error: "adapter error",
    error: "error"
  }

  def index(user, flash, snap) do
    fetch = snap.counters[Earss.Telemetry.event_feed_fetch()] || %{}
    poller = snap.counters[Earss.Telemetry.event_poller_tick()] || %{}
    translate = snap.counters[Earss.Telemetry.event_enrichment_translate()] || %{}
    pending = snap.counters[Earss.Telemetry.event_enrichment_pending()] || %{}
    retention = snap.counters[Earss.Telemetry.event_retention_run()] || %{}

    failure_rows =
      Enum.map(snap.failures, fn f ->
        label = Map.get(@failure_labels, f.outcome, to_string(f.outcome))

        """
        <tr>
          <td>#{HTML.h(f.link)}</td>
          <td>#{HTML.badge(label, "err")}</td>
          <td class="muted">#{HTML.time_ago(f.at)}</td>
        </tr>
        """
      end)
      |> Enum.join("\n")

    failures_block =
      if failure_rows == "" do
        ~s(<p class="empty">No failed fetches recorded.</p>)
      else
        ~s(<table><thead><tr><th>Feed</th><th>Outcome</th><th>At</th></tr></thead>) <>
          ~s(<tbody>#{failure_rows}</tbody></table>)
      end

    inner = """
    <div class="card row">
      <div class="stat"><div class="muted">Uptime</div><div class="n">#{uptime(snap.started_at)}</div></div>
      <div class="stat"><div class="muted">Fetches</div><div class="n">#{total(fetch)}</div></div>
      <div class="stat"><div class="muted">Failed fetches</div><div class="n">#{failures_total(fetch)}</div></div>
      <div class="stat"><div class="muted">Poller ticks</div><div class="n">#{Map.get(poller, :total, 0)}</div></div>
      <div class="stat"><div class="muted">Retention runs</div><div class="n">#{Map.get(retention, :total, 0)}</div></div>
    </div>

    <div class="grid2">
      #{outcome_card("Feed fetch", @fetch_outcomes, fetch, snap, Earss.Telemetry.event_feed_fetch())}
      #{count_card("Poller cycle", poller, snap, Earss.Telemetry.event_poller_tick())}
    </div>

    <div class="grid2">
      #{count_card("Ingest-hook translation", translate, snap, Earss.Telemetry.event_enrichment_translate())}
      #{count_card("Pending-worker retry", pending, snap, Earss.Telemetry.event_enrichment_pending())}
    </div>

    <div class="card">
      <h2>Recent fetch failures</h2>
      #{failures_block}
      <form method="post" action="/admin/metrics/reset" class="stack-actions" style="margin-top:.75rem">#{HTML.csrf_input()}
        <button type="submit" class="danger">Reset all metrics</button>
      </form>
    </div>
    """

    HTML.shell(user, flash, "Metrics", inner, active: "metrics", meta_refresh: 30)
  end

  ## Internal

  defp outcome_card(title, outcome_labels, counters, snap, event) do
    rows =
      Enum.map(outcome_labels, fn {key, label} ->
        case Map.get(counters, key, 0) do
          0 -> ""
          n -> "<tr><td>#{label}</td><td>#{n}</td></tr>"
        end
      end)
      |> Enum.join("\n")

    """
    <div class="card">
      <h2>#{title}</h2>
      <table>
        <thead><tr><th>Outcome</th><th>Count</th></tr></thead>
        <tbody>
          #{if rows == "", do: ~s(<tr><td colspan="2" class="empty">No events yet.</td></tr>), else: rows}
        </tbody>
      </table>
      #{latency_block(snap, event)}
    </div>
    """
  end

  defp count_card(title, counters, snap, event) do
    n = Map.get(counters, :total, 0)

    """
    <div class="card">
      <h2>#{title}</h2>
      <p class="stat" style="margin:0"><span class="n">#{n}</span>
        <span class="muted"> total</span></p>
      #{latency_block(snap, event)}
    </div>
    """
  end

  defp latency_block(snap, event) do
    case snap.latency[event] do
      nil ->
        ~s(<p class="muted" style="margin-top:.5rem">Latency: —</p>)

      %{count: c, sum: s, min: mn, max: mx} ->
        avg = div(s, c)

        "<p class=\"muted\" style=\"margin-top:.5rem\">Latency (avg/min/max): " <>
          "<strong>#{fmt_ms(avg)}</strong> / #{fmt_ms(mn)} / #{fmt_ms(mx)} over #{c} events</p>"
    end
  end

  defp fmt_ms(native) do
    ms = System.convert_time_unit(native, :native, :millisecond)
    "#{ms} ms"
  end

  defp total(counters), do: counters |> Map.values() |> Enum.sum()

  defp failures_total(counters) do
    Enum.reduce(counters, 0, fn {key, n}, acc ->
      if key in [:http_error, :parse_error, :adapter_error, :error], do: acc + n, else: acc
    end)
  end

  defp uptime(nil), do: "—"

  defp uptime(started_at) do
    secs = max(DateTime.diff(DateTime.utc_now(), started_at), 0)
    days = div(secs, 86_400)
    hours = div(rem(secs, 86_400), 3_600)
    mins = div(rem(secs, 3_600), 60)

    cond do
      days > 0 -> "#{days}d #{hours}h"
      hours > 0 -> "#{hours}h #{mins}m"
      true -> "#{mins}m"
    end
  end
end
