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
#      POLLER_MAX_CONCURRENCY, POLLER_INITIAL_DELAY_MS, POLLER_TIMEOUT_MS
config :earss, :poller,
  enabled: true,
  interval_ms: 5 * 60 * 1000,
  batch_size: 50,
  max_concurrency: 5,
  initial_delay_ms: 1_000,
  timeout_ms: 60_000

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

# Per-host crawl politeness — see Earss.Feeds.HostLimiter
# Env: HOST_POLITENESS_ENABLED, HOST_MAX_CONCURRENT, HOST_MIN_INTERVAL_MS,
#      HOST_DEFAULT_COOLDOWN_MS, HOST_CHECKOUT_TIMEOUT_MS
config :earss, :host_politeness,
  enabled: true,
  max_concurrent_per_host: 2,
  min_interval_ms: 1_000,
  default_cooldown_ms: 60_000,
  checkout_timeout_ms: 30_000

# Single-operator credentials are read from the operator environment
# (ADMIN_PASSWORD / FEVER_API_KEY) by Earss.OperatorAuth — see earss.env.example.
# Entry HTML body scrub (content/summary) at upsert — see Earss.Feeds.HTMLSanitize
config :earss, :html_sanitize, enabled: true

# Content enrichment / translation — see Earss.Enrichment
# Env: TRANSLATE_MAX_CONCURRENCY, TRANSLATE_PENDING_WORKER_INTERVAL_MS,
#      TRANSLATE_MAX_PENDING_RETRIES
config :earss, :translate,
  # Provider calls in flight at once (serializes slow local models)
  max_concurrency: 1,
  # Retry cadence for pending entries
  pending_worker: %{interval_ms: 60_000},
  # Per-feed ingest hook cap (entries per refresh)
  budget: %{max_entries: 20, max_chars: 100_000},
  # Consecutive failures before an entry is paused for an admin decision
  max_pending_retries: 5

# HTTP API (Plug + Bandit) — see Earss.API
# Env: API_ENABLED, PORT, SECRET_KEY_BASE, TOKEN_MAX_AGE_SECS
config :earss, :api,
  enabled: true,
  port: 4000,
  # Override in runtime/prod. Generate with: :crypto.strong_rand_bytes(32) |> Base.encode64()
  # Must be at least 64 bytes for Plug.Session cookie store
  secret_key_base: "dev-only-change-me-earss-api-secret-key-base-please-override-in-prod-64b+",
  token_max_age_secs: 60 * 60 * 24 * 30

# Telemetry store + /admin/metrics — see Earss.Telemetry / Earss.Telemetry.Store
# In-memory aggregation only; no persistence and no extra deps.
config :earss, :telemetry,
  enabled: true,
  # Max failed fetches kept for the problem ranking
  recent_failures: 50

# Listen-later controls (TTS intent capture) — see Earss.TTS / Earss.API.ListenControls.
# Env: EARSS_TTS_LISTEN_CONTROLS, EARSS_TTS_PUBLIC_URL, EARSS_TTS_AUDIO_DIR,
#      EARSS_TTS_WORKER_ENABLED, EARSS_TTS_WORKER_INTERVAL_MS,
#      EARSS_TTS_MAX_CONCURRENCY, EARSS_TTS_MAX_RETRIES
# (TTS_MAX_CHARS_SYNC and TTS_POLL_INTERVAL_MS are not wired to env; tune
# them via config.exs if needed.)
config :earss, :tts,
  listen_controls: false,
  # Optional absolute base URL override for injected listen links. By default
  # the link reuses the reader request's own scheme/host; set this only when
  # browsers must reach a different address than the reader does (reverse
  # proxy, tunnel, custom domain).
  public_url: nil,
  # Synthesis storage. nil keeps the worker idle even when enabled.
  audio_dir: nil,
  # Opaque keyword passed verbatim to provider calls (they also read their
  # own EARSS_TTS_* env).
  provider_opts: [],
  # Earss.TTS.Worker
  worker: [
    enabled: false,
    interval_ms: 30_000,
    batch_size: 5,
    max_retries: 5,
    poll_interval_ms: 2_000,
    poll_attempts: 60,
    # Host-side sync/async threshold — keep aligned with the provider's own
    # synchronous limit (Fish Audio reference: 2500).
    max_chars_sync: 2_500
  ]

# Inbound rate limiting for authentication failures (admin login, API login,
# Fever, GReader ClientLogin) — see Earss.RateLimit. Only failures are
# limited; a correct credential always passes and clears the key. Tests
# disable the limiter entirely.
config :earss, :rate_limit,
  enabled: true,
  max_failures: 5,
  window_secs: 60,
  lock_secs: 300,
  # Route-wide backstop: bounds the guessing rate even when an attacker
  # rotates X-Forwarded-For identities.
  global_max_failures: 30,
  # X-Forwarded-For is honoured only from these proxy CIDRs. Behind
  # Tailscale Funnel set ["100.64.0.0/10"]; direct exposure should keep [].
  trusted_proxies: []

import_config "#{config_env()}.exs"
