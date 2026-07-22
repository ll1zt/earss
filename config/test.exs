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

config :earss, :poller, enabled: false
config :earss, :retention_poller, enabled: false

config :earss, :api,
  enabled: false,
  port: 4001,
  secret_key_base: "test-secret-key-base-for-earss-api-tokens-and-sessions-must-be-64b+",
  token_max_age_secs: 3600
