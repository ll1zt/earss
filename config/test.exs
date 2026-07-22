import Config

config :earss, Earss.Repo,
  database: "earss_test",
  username: "postgres",
  password: "",
  hostname: "localhost",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :logger, level: :warning

# 测试中加速 Argon2
config :argon2_elixir,
  t_cost: 1,
  m_cost: 8
