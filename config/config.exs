import Config

config :earss,
  ecto_repos: [Earss.Repo]

# 刷新间隔全局默认（分钟）— 与 feeds 表默认值一致（D7）
config :earss, :refresh,
  min_interval: 15,
  max_interval: 10_080,
  default_interval: 30

# 数据保留（天）— 见 docs/data_lifecycle.md
config :earss, :retention,
  read_state_days: 90,
  entry_days: 180,
  unsubscribed_feed_days: 30

# Feed poller (GenServer) — see Earss.FeedPoller
config :earss, :poller,
  enabled: true,
  interval_ms: 5 * 60 * 1000,
  batch_size: 50,
  max_concurrency: 5

# Retention poller — see Earss.Retention / Earss.RetentionPoller
config :earss, :retention_poller,
  enabled: true,
  interval_ms: 24 * 60 * 60 * 1000,
  batch_size: 1000,
  initial_delay_ms: 60_000

# HTTP API (Plug + Bandit) — see Earss.API
config :earss, :api,
  enabled: true,
  port: 4000,
  # Override in runtime/prod. Generate with: :crypto.strong_rand_bytes(32) |> Base.encode64()
  secret_key_base: "dev-only-change-me-earss-api-secret-key-base-32b",
  token_max_age_secs: 60 * 60 * 24 * 30

import_config "#{config_env()}.exs"
