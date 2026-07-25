import Config

config :earss,
  ecto_repos: [Earss.Repo]

# Defaults below can be overridden at runtime via env / earss.env
# (see config/runtime.exs and earss.env.example).

# 刷新间隔全局默认（分钟）— 与 feeds 表默认值一致（D7）
# Env: REFRESH_MIN_INTERVAL, REFRESH_MAX_INTERVAL, REFRESH_DEFAULT_INTERVAL
config :earss, :refresh,
  min_interval: 15,
  max_interval: 10_080,
  default_interval: 30

# 数据保留（天）— 见 docs/data_lifecycle.md
# Env: RETENTION_READ_STATE_DAYS, RETENTION_ENTRY_DAYS, RETENTION_UNSUBSCRIBED_FEED_DAYS
config :earss, :retention,
  read_state_days: 90,
  entry_days: 180,
  unsubscribed_feed_days: 30

# Feed poller (GenServer) — see Earss.FeedPoller
# Env: POLLER_ENABLED, POLLER_INTERVAL_MS, POLLER_BATCH_SIZE,
#      POLLER_MAX_CONCURRENCY, POLLER_INITIAL_DELAY_MS
config :earss, :poller,
  enabled: true,
  interval_ms: 5 * 60 * 1000,
  batch_size: 50,
  max_concurrency: 5,
  initial_delay_ms: 1_000

# Retention poller — see Earss.Retention / Earss.RetentionPoller
# Env: RETENTION_POLLER_ENABLED, RETENTION_POLLER_INTERVAL_MS,
#      RETENTION_BATCH_SIZE, RETENTION_INITIAL_DELAY_MS
config :earss, :retention_poller,
  enabled: true,
  interval_ms: 24 * 60 * 60 * 1000,
  batch_size: 1000,
  initial_delay_ms: 60_000

# Outbound HTTP for feed fetches — see Earss.Feeds.HTTP.ReqClient
# Env: HTTP_RECEIVE_TIMEOUT_MS, HTTP_USER_AGENT
config :earss, :http,
  receive_timeout: 15_000,
  user_agent: "Earss/0.1 (+https://github.com/ll1zt/earss)"

# Entry HTML body scrub (content/summary) at upsert — see Earss.Feeds.HTMLSanitize
config :earss, :html_sanitize,
  enabled: true

# HTTP API (Plug + Bandit) — see Earss.API
# Env: API_ENABLED, PORT, SECRET_KEY_BASE, TOKEN_MAX_AGE_SECS
config :earss, :api,
  enabled: true,
  port: 4000,
  # Override in runtime/prod. Generate with: :crypto.strong_rand_bytes(32) |> Base.encode64()
  # Must be at least 64 bytes for Plug.Session cookie store
  secret_key_base: "dev-only-change-me-earss-api-secret-key-base-please-override-in-prod-64b+",
  token_max_age_secs: 60 * 60 * 24 * 30

import_config "#{config_env()}.exs"
