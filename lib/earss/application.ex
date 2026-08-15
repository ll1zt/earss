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
        maybe_child(Earss.Telemetry.Store, :telemetry) ++
        maybe_child(Earss.RateLimit, :rate_limit) ++
        maybe_child(Earss.FeedPoller, :poller) ++
        maybe_child(Earss.RetentionPoller, :retention_poller) ++
        api_child()

    opts = [strategy: :one_for_one, name: Earss.Supervisor]

    with {:ok, pid} <- Supervisor.start_link(children, opts),
         :ok <- start_optional_plugins(),
         :ok <- register_builtin_sources(),
         :ok <- Earss.Plugins.register_all(Earss.Plugins.source()),
         :ok <- Earss.Plugins.register_all(Earss.Plugins.translate()),
         :ok <- Earss.Telemetry.attach_default_handler(),
         :ok <- Earss.OperatorAuth.validate_credentials() do
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
