defmodule Earss.Admin.Views.Settings do
  @moduledoc false

  alias Earss.Admin.HTML
  alias Earss.Admin.Helpers
  alias Earss.OperatorAuth

  def page(operator, flash, fever_url) do
    fever_key = OperatorAuth.fever_api_key()
    fever_set? = is_binary(fever_key) and fever_key != ""

    key_short =
      cond do
        fever_set? and byte_size(fever_key) > 12 ->
          String.slice(fever_key, 0, 8) <> "…" <> String.slice(fever_key, -4, 4)

        fever_set? ->
          fever_key

        true ->
          "(not set)"
      end

    env_cheat =
      [
        {"ADMIN_PASSWORD", "Admin login password",
         if(OperatorAuth.admin_password(), do: "set", else: "(not set)")},
        {"FEVER_API_KEY", "Fever / NetNewsWire key", (fever_set? && "set") || "(not set)"},
        {"PORT", "HTTP port",
         to_string(Keyword.get(Application.get_env(:earss, :api, []), :port))},
        {"POLLER_INTERVAL_MS", "Feed poll interval",
         Helpers.format_interval_ms(
           Keyword.get(Application.get_env(:earss, :poller, []), :interval_ms)
         )},
        {"RETENTION_READ_STATE_DAYS", "Read-state retention",
         "#{Keyword.get(Application.get_env(:earss, :retention, []), :read_state_days)} days"},
        {"RETENTION_ENTRY_DAYS", "Entry retention",
         "#{Keyword.get(Application.get_env(:earss, :retention, []), :entry_days)} days"},
        {"HOST_MAX_CONCURRENT", "Per-host crawl limit",
         to_string(
           Keyword.get(
             Application.get_env(:earss, :host_politeness, []),
             :max_concurrent_per_host
           )
         )},
        {"TRANSLATE_MAX_CONCURRENCY", "Provider calls in flight",
         to_string(Keyword.get(Application.get_env(:earss, :translate, []), :max_concurrency))}
      ]
      |> Enum.map(fn {env, label, value} ->
        "<tr><td><code>#{env}</code></td><td>#{label}</td><td>#{HTML.h(value)}</td></tr>"
      end)
      |> Enum.join("\n")

    inner = """
    <div class="card">
      <h2>Fever / NetNewsWire</h2>
      <p>URL: <code>#{HTML.h(fever_url)}</code></p>
      <p class="muted">
        Credentials come from the operator environment (single-operator mode):
        <code>FEVER_API_KEY</code> in <code>earss.env</code>.
        Configure it there and restart the app.
      </p>
      <p class="muted">Configured api key: <code>#{HTML.h(key_short)}</code></p>
    </div>
    <div class="card">
      <h2>Login password</h2>
      <p class="muted">
        The admin login uses <code>ADMIN_PASSWORD</code> from
        <code>earss.env</code> (or the environment). Change it there and
        restart the app — passwords are no longer stored in the database.
      </p>
    </div>
    <div class="card">
      <h2>Operator environment (current values)</h2>
      <table class="compact-table">
        <thead><tr><th>Env var</th><th>What it does</th><th>Current</th></tr></thead>
        <tbody>#{env_cheat}</tbody>
      </table>
      <p class="muted" style="margin-top:.5rem">Set these in <code>earss.env</code> (or the process environment) and restart the app. Full list: <code>earss.env.example</code>.</p>
    </div>
    """

    HTML.shell(operator, flash, "Settings", inner, active: "settings")
  end
end
