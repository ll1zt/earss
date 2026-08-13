defmodule Earss.Release do
  @moduledoc """
  Tasks executed inside a production release (no Mix).

  Examples (from the release root):

      bin/earss eval "Earss.Release.migrate()"
      bin/earss eval "Earss.Release.seed_admin(\\"admin\\", \\"change-me\\")"
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

  @doc """
  Seed the single operator's anchor user row (single-operator mode — the
  users table exists only until the db-schema-v2 migration).

  Idempotent: returns `{:ok, :exists}` when a row is already present,
  otherwise `{:ok, :seeded}`.
  """
  def seed_operator do
    load_app()

    [repo | _] = repos()

    {:ok, result, _} =
      Ecto.Migrator.with_repo(repo, fn repo ->
        import Ecto.Query

        case repo.one(from(u in Earss.Reader.User, limit: 1)) do
          %{id: _} ->
            {:ok, :exists}

          nil ->
            repo.insert(
              Earss.Reader.User.changeset(%Earss.Reader.User{}, %{
                username: "operator",
                password_hash: "operator-anchor",
                user_type: "admin"
              })
            )
            |> case do
              {:ok, _} -> {:ok, :seeded}
              {:error, changeset} -> {:error, changeset}
            end
        end
      end)

    case result do
      {:ok, _} = ok -> ok
      {:error, _} = err -> err
    end
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
