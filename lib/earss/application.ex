defmodule Earss.Application do
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    children =
      [
        Earss.Source.Registry,
        Earss.Enrichment.Registry,
        Earss.Enrichment.Limiter,
        {Task.Supervisor, name: Earss.Enrichment.TaskSupervisor},
        {Earss.Enrichment.PendingWorker, Application.get_env(:earss, :translate, [])},
        Earss.Repo,
        {Earss.Feeds.HostLimiter, Application.get_env(:earss, :host_politeness, [])}
      ] ++
        maybe_child(Earss.FeedPoller, :poller) ++
        maybe_child(Earss.RetentionPoller, :retention_poller) ++
        api_child()

    opts = [strategy: :one_for_one, name: Earss.Supervisor]

    with {:ok, pid} <- Supervisor.start_link(children, opts),
         :ok <- start_optional_plugins(),
         :ok <- register_builtin_sources(),
         :ok <- register_loaded_plugins(),
         :ok <- register_loaded_enrichers(),
         :ok <- Earss.Bootstrap.ensure_default_admin() do
      {:ok, pid}
    end
  end

  # Optional source/translate plugins are `runtime: false` deps (env-driven),
  # so OTP never auto-starts them and a broken/removed plugin cannot stop the
  # app from booting. Start them explicitly here — their Application.start
  # registers with the registries, which discovery below then also picks up.
  # App names are captured at compile time from the operator env.
  @optional_plugin_apps Earss.MixProject.optional_plugin_apps()

  defp start_optional_plugins do
    Enum.each(@optional_plugin_apps, fn app ->
      case Application.ensure_all_started(app) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.error("optional plugin #{app} failed to start: #{inspect(reason)}")
      end
    end)

    :ok
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

  # Optional translation plugins: config, EARSS_TRANSLATE_ADAPTERS, and loaded
  # earss_translate_* apps (convention: app :earss_translate_foo →
  # module EarssTranslateFoo.Translator).
  defp register_loaded_enrichers do
    mods =
      Application.get_env(:earss, :translate_adapters, []) ++
        env_enricher_modules() ++
        discovered_plugin_enrichers()

    Enum.each(Enum.uniq(mods), &register_enricher_module/1)
    :ok
  end

  # Explicit modules: EARSS_TRANSLATE_ADAPTERS=EarssTranslateOpenai.Translator
  defp env_enricher_modules do
    case System.get_env("EARSS_TRANSLATE_ADAPTERS") do
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

  # Convention: Mix app :earss_translate_foo → module EarssTranslateFoo.Translator
  defp discovered_plugin_enrichers do
    Application.loaded_applications()
    |> Enum.map(fn {app, _desc, _vsn} -> app end)
    |> Enum.filter(fn app ->
      s = Atom.to_string(app)
      String.starts_with?(s, "earss_translate_")
    end)
    |> Enum.map(fn app ->
      Module.concat([Macro.camelize(Atom.to_string(app)), "Translator"])
    end)
    |> Enum.filter(fn mod -> match?({:module, _}, Code.ensure_loaded(mod)) end)
  end

  defp register_enricher_module(mod) when is_atom(mod) do
    if function_exported?(mod, :id, 0) do
      _ =
        Earss.Enrichment.Registry.register(%{
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
