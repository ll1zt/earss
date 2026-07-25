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
         :ok <- register_builtin_sources() do
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
