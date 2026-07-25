import Config

# Shared loader for earss.env / earss.env.local (see config/env_loader.exs).
Code.require_file(Path.expand("env_loader.exs", __DIR__))

# Tests use config/test.exs only (sandbox DB, pollers off). Do not let a
# developer's earss.env or shell operator vars rewrite that.
if config_env() != :test do
  Earss.EnvLoader.load_files(Path.expand("..", __DIR__))
  alias Earss.EnvLoader

  # ---------------------------------------------------------------------------
  # Database
  # ---------------------------------------------------------------------------

  repo_opts = []

  repo_opts =
    case EnvLoader.fetch_str("DATABASE_URL") do
      {:ok, url} -> Keyword.put(repo_opts, :url, url)
      :unset -> repo_opts
    end

  repo_opts =
    case EnvLoader.fetch_int("POOL_SIZE") do
      {:ok, n} -> Keyword.put(repo_opts, :pool_size, n)
      :unset -> repo_opts
    end

  if repo_opts != [] do
    config :earss, Earss.Repo, repo_opts
  end

  if config_env() == :prod and is_nil(EnvLoader.get("DATABASE_URL")) do
    raise """
    environment variable DATABASE_URL is missing.
    For example: ecto://USER:PASS@HOST/DATABASE
    """
  end

  # ---------------------------------------------------------------------------
  # HTTP API
  # ---------------------------------------------------------------------------

  api_opts = []

  api_opts =
    case EnvLoader.fetch_bool("API_ENABLED") do
      {:ok, v} -> Keyword.put(api_opts, :enabled, v)
      :unset -> api_opts
    end

  api_opts =
    case EnvLoader.fetch_int("PORT") do
      {:ok, n} -> Keyword.put(api_opts, :port, n)
      :unset -> api_opts
    end

  api_opts =
    case EnvLoader.fetch_int("TOKEN_MAX_AGE_SECS") do
      {:ok, n} -> Keyword.put(api_opts, :token_max_age_secs, n)
      :unset -> api_opts
    end

  api_opts =
    case {EnvLoader.fetch_str("SECRET_KEY_BASE"), config_env()} do
      {{:ok, secret}, _} ->
        Keyword.put(api_opts, :secret_key_base, secret)

      {:unset, :prod} ->
        raise """
        environment variable SECRET_KEY_BASE is missing.
        Generate one with: openssl rand -base64 48
        """

      {:unset, _} ->
        api_opts
    end

  if api_opts != [] do
    config :earss, :api, api_opts
  end

  # ---------------------------------------------------------------------------
  # Feed poller
  # ---------------------------------------------------------------------------

  poller_opts = []

  poller_opts =
    case EnvLoader.fetch_bool("POLLER_ENABLED") do
      {:ok, v} -> Keyword.put(poller_opts, :enabled, v)
      :unset -> poller_opts
    end

  poller_opts =
    case EnvLoader.fetch_int("POLLER_INTERVAL_MS") do
      {:ok, n} -> Keyword.put(poller_opts, :interval_ms, n)
      :unset -> poller_opts
    end

  poller_opts =
    case EnvLoader.fetch_int("POLLER_BATCH_SIZE") do
      {:ok, n} -> Keyword.put(poller_opts, :batch_size, n)
      :unset -> poller_opts
    end

  poller_opts =
    case EnvLoader.fetch_int("POLLER_MAX_CONCURRENCY") do
      {:ok, n} -> Keyword.put(poller_opts, :max_concurrency, n)
      :unset -> poller_opts
    end

  poller_opts =
    case EnvLoader.fetch_int("POLLER_INITIAL_DELAY_MS") do
      {:ok, n} -> Keyword.put(poller_opts, :initial_delay_ms, n)
      :unset -> poller_opts
    end

  if poller_opts != [] do
    config :earss, :poller, poller_opts
  end

  # ---------------------------------------------------------------------------
  # Retention policy + poller
  # ---------------------------------------------------------------------------

  retention_opts = []

  retention_opts =
    case EnvLoader.fetch_int("RETENTION_READ_STATE_DAYS") do
      {:ok, n} -> Keyword.put(retention_opts, :read_state_days, n)
      :unset -> retention_opts
    end

  retention_opts =
    case EnvLoader.fetch_int("RETENTION_ENTRY_DAYS") do
      {:ok, n} -> Keyword.put(retention_opts, :entry_days, n)
      :unset -> retention_opts
    end

  retention_opts =
    case EnvLoader.fetch_int("RETENTION_UNSUBSCRIBED_FEED_DAYS") do
      {:ok, n} -> Keyword.put(retention_opts, :unsubscribed_feed_days, n)
      :unset -> retention_opts
    end

  if retention_opts != [] do
    config :earss, :retention, retention_opts
  end

  ret_poller_opts = []

  ret_poller_opts =
    case EnvLoader.fetch_bool("RETENTION_POLLER_ENABLED") do
      {:ok, v} -> Keyword.put(ret_poller_opts, :enabled, v)
      :unset -> ret_poller_opts
    end

  ret_poller_opts =
    case EnvLoader.fetch_int("RETENTION_POLLER_INTERVAL_MS") do
      {:ok, n} -> Keyword.put(ret_poller_opts, :interval_ms, n)
      :unset -> ret_poller_opts
    end

  ret_poller_opts =
    case EnvLoader.fetch_int("RETENTION_BATCH_SIZE") do
      {:ok, n} -> Keyword.put(ret_poller_opts, :batch_size, n)
      :unset -> ret_poller_opts
    end

  ret_poller_opts =
    case EnvLoader.fetch_int("RETENTION_INITIAL_DELAY_MS") do
      {:ok, n} -> Keyword.put(ret_poller_opts, :initial_delay_ms, n)
      :unset -> ret_poller_opts
    end

  if ret_poller_opts != [] do
    config :earss, :retention_poller, ret_poller_opts
  end

  # ---------------------------------------------------------------------------
  # Refresh intervals (minutes) — D7
  # ---------------------------------------------------------------------------

  refresh_opts = []

  refresh_opts =
    case EnvLoader.fetch_int("REFRESH_MIN_INTERVAL") do
      {:ok, n} -> Keyword.put(refresh_opts, :min_interval, n)
      :unset -> refresh_opts
    end

  refresh_opts =
    case EnvLoader.fetch_int("REFRESH_MAX_INTERVAL") do
      {:ok, n} -> Keyword.put(refresh_opts, :max_interval, n)
      :unset -> refresh_opts
    end

  refresh_opts =
    case EnvLoader.fetch_int("REFRESH_DEFAULT_INTERVAL") do
      {:ok, n} -> Keyword.put(refresh_opts, :default_interval, n)
      :unset -> refresh_opts
    end

  if refresh_opts != [] do
    config :earss, :refresh, refresh_opts
  end

  # ---------------------------------------------------------------------------
  # Outbound HTTP (feed fetch)
  # ---------------------------------------------------------------------------

  http_opts = []

  http_opts =
    case EnvLoader.fetch_int("HTTP_RECEIVE_TIMEOUT_MS") do
      {:ok, n} -> Keyword.put(http_opts, :receive_timeout, n)
      :unset -> http_opts
    end

  http_opts =
    case EnvLoader.fetch_str("HTTP_USER_AGENT") do
      {:ok, ua} -> Keyword.put(http_opts, :user_agent, ua)
      :unset -> http_opts
    end

  if http_opts != [] do
    config :earss, :http, http_opts
  end
end
