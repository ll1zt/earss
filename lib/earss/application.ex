defmodule Earss.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [Earss.Repo] ++
        maybe_child(Earss.FeedPoller, :poller) ++
        maybe_child(Earss.RetentionPoller, :retention_poller)

    opts = [strategy: :one_for_one, name: Earss.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp maybe_child(module, config_key) do
    cfg = Application.get_env(:earss, config_key, [])

    if Keyword.get(cfg, :enabled, true) do
      [{module, cfg}]
    else
      []
    end
  end
end
