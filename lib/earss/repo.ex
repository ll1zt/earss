defmodule Earss.Repo do
  use Ecto.Repo,
    otp_app: :earss,
    adapter: Ecto.Adapters.Postgres
end
