defmodule Earss.Admin.Views.Sources do
  @moduledoc false

  alias Earss.Admin.HTML
  alias Earss.Admin.Helpers

  def index(user, flash, assigns) do
    %{adapters: adapters, routes: routes, cats: cats} = assigns
    cat_opts = Helpers.category_options(cats, nil)

    adapter_rows =
      adapters
      |> Enum.map(fn a ->
        mod = Map.get(a, :module)
        ver = Map.get(a, :version) || "—"
        api = safe_adapter_api(mod)

        """
        <tr>
          <td><code>#{HTML.h(a.id)}</code></td>
          <td><code>#{HTML.h(inspect(mod))}</code></td>
          <td class="muted">#{HTML.h(to_string(ver))}</td>
          <td class="muted">#{HTML.h(to_string(api))}</td>
        </tr>
        """
      end)
      |> Enum.join("\n")

    adapter_block =
      if adapter_rows == "" do
        """
        <p class="empty">No adapters registered — native should always be present.</p>
        """
      else
        """
        <table class="compact-table">
          <thead><tr><th>Id</th><th>Module</th><th>Version</th><th>API</th></tr></thead>
          <tbody>#{adapter_rows}</tbody>
        </table>
        """
      end

    plugin_routes = Enum.reject(routes, fn r -> Map.get(r, :adapter_id) == "native" end)

    route_cards =
      if plugin_routes == [] do
        """
        <p class="empty">No plugin routes registered. Stock Earss only has the native HTTP feed adapter
        (subscribe with an <code>https://</code> URL under Subscriptions). Optional plugins such as
        <a href="https://github.com/ll1zt/earss_source_telegram">earss_source_telegram</a>
        expose routes here when enabled (<code>EARSS_TELEGRAM_PLUGIN=1</code>).</p>
        """
      else
        plugin_routes
        |> Enum.map(&route_card(&1, cat_opts))
        |> Enum.join("\n")
      end

    inner = """
    <div class="card">
      <h2>Registered adapters</h2>
      <p class="muted">Source adapters implement <code>Earss.Source.Adapter</code> and register on boot.
      Classic RSS/Atom/JSON uses <code>native</code>. Plugin feeds use <code>earss://&lt;adapter&gt;/…</code>.</p>
      #{adapter_block}
    </div>

    <div class="card">
      <h2>Subscribe by URL</h2>
      <p class="muted">Paste any feed URL or <code>earss://</code> source. Same pipeline as Subscriptions.</p>
      <form method="post" action="/admin/sources/subscribe">#{HTML.csrf_input()}
        <label>Link</label>
        <input name="link" type="text" required placeholder="earss://telegram/channel/journey_of_someone"/>
        <label>Category</label>
        <select name="category_id">#{cat_opts}</select>
        <label class="inline-check"><input type="checkbox" name="refresh" value="true" checked/> Fetch now</label>
        <div><button type="submit">Subscribe</button></div>
      </form>
    </div>

    <div class="card">
      <h2>Plugin routes</h2>
      #{route_cards}
    </div>

    <div class="card">
      <h2>Notes</h2>
      <ul class="muted" style="margin:0;padding-left:1.2rem">
        <li>HTTPS feed documents: prefer <a href="/admin/subscriptions">Subscriptions</a>.</li>
        <li>Plugin markup/API changes are owned by the plugin package, not Earss core.</li>
        <li>Docs: <code>docs/sources.md</code>.</li>
      </ul>
    </div>
    """

    HTML.shell(user, flash, "Sources", inner, active: "sources")
  end

  defp route_card(route, cat_opts) do
    adapter_id = Map.get(route, :adapter_id) || ""
    path = Map.get(route, :path) || Map.get(route, "path") || ""
    desc = Map.get(route, :description) || Map.get(route, "description") || ""
    example = Map.get(route, :example) || Map.get(route, "example")
    params = Map.get(route, :params) || Map.get(route, "params") || []

    param_fields =
      params
      |> List.wrap()
      |> Enum.map(fn p ->
        name = param_name(p)
        example_v = param_example(p)
        req? = param_required?(p)

        """
        <div class="field">
          <label>#{HTML.h(name)}#{if req?, do: " *", else: ""}</label>
          <input name="param_#{HTML.h(name)}" #{if req?, do: "required", else: ""}
            placeholder="#{HTML.h(example_v || name)}"/>
        </div>
        """
      end)
      |> Enum.join("\n")

    # If route has :params in path but no params list, extract from path
    param_fields =
      if param_fields == "" do
        path
        |> path_param_names()
        |> Enum.map(fn name ->
          """
          <div class="field">
            <label>#{HTML.h(name)} *</label>
            <input name="param_#{HTML.h(name)}" required placeholder="#{HTML.h(name)}"/>
          </div>
          """
        end)
        |> Enum.join("\n")
      else
        param_fields
      end

    example_line =
      if is_binary(example) and example != "" do
        ~s(<p class="muted">Example: <code>#{HTML.h(example)}</code></p>)
      else
        ~s(<p class="muted">Builds <code>earss://#{HTML.h(adapter_id)}/#{HTML.h(path)}</code></p>)
      end

    """
    <div class="card" style="margin-top:0.75rem">
      <h2 style="margin-top:0"><code>#{HTML.h(adapter_id)}</code> · <code>#{HTML.h(path)}</code></h2>
      <p class="muted">#{HTML.h(desc)}</p>
      #{example_line}
      <form method="post" action="/admin/sources/subscribe" class="filters">#{HTML.csrf_input()}
        <input type="hidden" name="adapter_id" value="#{HTML.h(adapter_id)}"/>
        <input type="hidden" name="path" value="#{HTML.h(path)}"/>
        #{param_fields}
        <div class="field">
          <label>Category</label>
          <select name="category_id">#{cat_opts}</select>
        </div>
        <div class="field">
          <label class="inline-check" style="margin-top:1.2rem"><input type="checkbox" name="refresh" value="true" checked/> Fetch now</label>
        </div>
        <div class="field">
          <button type="submit">Subscribe route</button>
        </div>
      </form>
    </div>
    """
  end

  defp param_name(%{name: n}) when is_binary(n), do: n
  defp param_name(%{"name" => n}) when is_binary(n), do: n
  defp param_name(n) when is_binary(n), do: n
  defp param_name(_), do: "param"

  defp param_example(%{example: e}) when is_binary(e), do: e
  defp param_example(%{"example" => e}) when is_binary(e), do: e
  defp param_example(_), do: nil

  defp param_required?(%{required: false}), do: false
  defp param_required?(%{"required" => false}), do: false
  defp param_required?(_), do: true

  defp path_param_names(path) when is_binary(path) do
    Regex.scan(~r/:([A-Za-z_][A-Za-z0-9_]*)/, path)
    |> Enum.map(fn [_, name] -> name end)
  end

  defp path_param_names(_), do: []

  defp safe_adapter_api(mod) when is_atom(mod) do
    if function_exported?(mod, :adapter_api, 0), do: mod.adapter_api(), else: "—"
  rescue
    _ -> "—"
  end

  defp safe_adapter_api(_), do: "—"
end
