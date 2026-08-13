defmodule Earss.Release do
  @moduledoc """
  Tasks executed inside a production release (no Mix).

  Examples (from the release root):

      bin/earss eval "Earss.Release.migrate()"
      bin/earss eval "Earss.Release.rollback(step: 1)"
  """

  @app :earss

  @doc "Run all pending Ecto migrations."
  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end

  @doc "Roll back migrations. Options: `step:` (default 1) or `to:` version."
  def rollback(opts \\ []) do
    load_app()
    step = Keyword.get(opts, :step)
    to = Keyword.get(opts, :to)

    for repo <- repos() do
      {:ok, _, _} =
        Ecto.Migrator.with_repo(repo, fn repo ->
          cond do
            is_integer(to) -> Ecto.Migrator.run(repo, :down, to: to)
            true -> Ecto.Migrator.run(repo, :down, step: step || 1)
          end
        end)
    end

    :ok
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
