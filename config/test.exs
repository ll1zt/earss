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

# Single-operator credentials are fixed for tests (config :earss, :operator_auth).
# Keep HostLimiter on but non-blocking for the bulk of the suite.
# Dedicated tests tighten these via Application.put_env/3.
config :earss, :host_politeness,
  enabled: true,
  max_concurrent_per_host: 32,
  min_interval_ms: 0,
  default_cooldown_ms: 60_000,
  checkout_timeout_ms: 5_000

config :earss, :api,
  enabled: false,
  port: 4001,
  secret_key_base: "test-secret-key-base-for-earss-api-tokens-and-sessions-must-be-64b+",
  token_max_age_secs: 3600

# Single-operator credentials (docs/single_user.md, C2). Tests authenticate
# with these fixed values instead of creating user rows.
config :earss, :operator_auth,
  admin_password: "test-password",
  fever_api_key: "test-fever-key"
