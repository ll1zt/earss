defmodule Earss.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        Earss.Repo
      ] ++ poller_child()

    opts = [strategy: :one_for_one, name: Earss.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp poller_child do
    if poller_enabled?() do
      [{Earss.FeedPoller, Application.get_env(:earss, :poller, [])}]
    else
      []
    end
  end

  defp poller_enabled? do
    Application.get_env(:earss, :poller, [])
    |> Keyword.get(:enabled, true)
  end
end
