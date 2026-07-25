defmodule Earss.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        Earss.Source.Registry,
        Earss.Repo
      ] ++
        maybe_child(Earss.FeedPoller, :poller) ++
        maybe_child(Earss.RetentionPoller, :retention_poller) ++
        api_child()

    opts = [strategy: :one_for_one, name: Earss.Supervisor]

    with {:ok, pid} <- Supervisor.start_link(children, opts),
         :ok <- register_builtin_sources(),
         :ok <- register_loaded_plugins() do
      {:ok, pid}
    end
  end

  defp register_builtin_sources do
    case Earss.Source.Registry.register(%{
           id: Earss.Source.Native.id(),
           module: Earss.Source.Native,
           version: "builtin"
         }) do
      :ok -> :ok
      {:error, :already_registered} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Optional source plugins are Mix deps that may start *before* this app and
  # fail to register (Registry not up yet). After we own the Registry, pick up
  # any loaded adapter modules listed in config or known reference plugins.
  defp register_loaded_plugins do
    mods =
      Application.get_env(:earss, :source_adapters, []) ++
        reference_plugin_adapters()

    Enum.each(Enum.uniq(mods), &register_adapter_module/1)
    :ok
  end

  defp reference_plugin_adapters do
    # Soft references (Module.concat so core compiles without the plugin package).
    ["EarssSourceTelegram.Adapter"]
    |> Enum.map(&Module.concat(String.split(&1, ".")))
    |> Enum.filter(fn mod -> match?({:module, _}, Code.ensure_loaded(mod)) end)
  end

  defp register_adapter_module(mod) when is_atom(mod) do
    if function_exported?(mod, :id, 0) do
      _ =
        Earss.Source.Registry.register(%{
          id: mod.id(),
          module: mod,
          version: "plugin"
        })
    end

    :ok
  rescue
    _ -> :ok
  end

  defp maybe_child(module, config_key) do
    cfg = Application.get_env(:earss, config_key, [])

    if Keyword.get(cfg, :enabled, true) do
      [{module, cfg}]
    else
      []
    end
  end

  defp api_child do
    cfg = Application.get_env(:earss, :api, [])

    if Keyword.get(cfg, :enabled, true) do
      port = Keyword.get(cfg, :port, 4000)

      [
        {Bandit, plug: Earss.API.Router, port: port, thousand_island_options: [num_acceptors: 10]}
      ]
    else
      []
    end
  end
end
