defmodule Earss.Repo do
  @moduledoc """
  The Ecto repository — the only door to PostgreSQL.

  Tests run under `Ecto.Adapters.SQL.Sandbox` in `:manual` mode, so every
  process that touches the DB (including spawned tasks) must be granted a
  connection explicitly.
  """

  use Ecto.Repo,
    otp_app: :earss,
    adapter: Ecto.Adapters.Postgres
end
