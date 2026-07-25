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
  # adapters from: config, EARSS_SOURCE_ADAPTERS, and loaded earss_source_* apps.
  defp register_loaded_plugins do
    mods =
      Application.get_env(:earss, :source_adapters, []) ++
        env_adapter_modules() ++
        discovered_plugin_adapters()

    Enum.each(Enum.uniq(mods), &register_adapter_module/1)
    :ok
  end

  # Explicit modules: EARSS_SOURCE_ADAPTERS=EarssSourceTelegram.Adapter,Other.Adapter
  defp env_adapter_modules do
    case System.get_env("EARSS_SOURCE_ADAPTERS") do
      nil ->
        []

      "" ->
        []

      raw ->
        raw
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.map(&Module.concat(String.split(&1, ".")))
        |> Enum.filter(fn mod -> match?({:module, _}, Code.ensure_loaded(mod)) end)
    end
  end

  # Convention: Mix app :earss_source_foo → module EarssSourceFoo.Adapter
  # (skips the contract app :earss_source itself).
  defp discovered_plugin_adapters do
    Application.loaded_applications()
    |> Enum.map(fn {app, _desc, _vsn} -> app end)
    |> Enum.filter(fn app ->
      s = Atom.to_string(app)
      String.starts_with?(s, "earss_source_")
    end)
    |> Enum.map(fn app ->
      Module.concat([Macro.camelize(Atom.to_string(app)), "Adapter"])
    end)
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
