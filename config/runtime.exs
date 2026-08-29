import Config

# Runtime config for every boot (dev/prod) and releases.
# Prefer process environment (systemd EnvironmentFile, Docker, shell).
# Optionally load project-root earss.env files when present (dev / bare metal).

# ---------------------------------------------------------------------------
# Optional env files (never overwrite already-set process env)
# ---------------------------------------------------------------------------

load_env_file = fn path ->
  if is_binary(path) and File.exists?(path) do
    path
    |> File.stream!()
    |> Stream.map(&String.trim/1)
    |> Stream.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    |> Enum.each(fn line ->
      case String.split(line, "=", parts: 2) do
        [key, value] ->
          key = String.trim(key)

          value =
            value
            |> String.trim()
            |> then(fn v ->
              cond do
                String.length(v) >= 2 and String.starts_with?(v, "\"") and
                    String.ends_with?(v, "\"") ->
                  String.slice(v, 1..-2//1)

                String.length(v) >= 2 and String.starts_with?(v, "'") and
                    String.ends_with?(v, "'") ->
                  String.slice(v, 1..-2//1)

                true ->
                  v
              end
            end)

          if key != "" and System.get_env(key) in [nil, ""] do
            System.put_env(key, value)
          end

        _ ->
          :ok
      end
    end)
  end
end

if config_env() != :test do
  cond do
    release_root = System.get_env("RELEASE_ROOT") ->
      # Mix release process: optional files beside the release root
      load_env_file.(Path.join(release_root, "earss.env"))
      load_env_file.(Path.join(release_root, "earss.env.local"))

    true ->
      # Source checkout / mix run: config/../earss.env
      root = Path.expand("..", __DIR__)
      load_env_file.(Path.join(root, "earss.env"))
      load_env_file.(Path.join(root, "earss.env.local"))
  end

  if env_dir = System.get_env("EARSS_ENV_DIR") do
    load_env_file.(Path.join(env_dir, "earss.env"))
    load_env_file.(Path.join(env_dir, "earss.env.local"))
  end
end

env = fn name ->
  case System.get_env(name) do
    nil -> nil
    "" -> nil
    v -> v
  end
end

fetch_str = fn name ->
  case env.(name) do
    nil -> :unset
    v -> {:ok, v}
  end
end

fetch_int = fn name ->
  case env.(name) do
    nil -> :unset
    v -> {:ok, String.to_integer(v)}
  end
end

fetch_bool = fn name ->
  case env.(name) do
    nil -> :unset
    v when v in ~w(true 1 yes on) -> {:ok, true}
    v when v in ~w(false 0 no off) -> {:ok, false}
    other -> raise "invalid boolean for #{name}: #{inspect(other)}"
  end
end

if config_env() != :test do
  # ---------------------------------------------------------------------------
  # Database
  #
  # Prefer either:
  #   DATABASE_URL=ecto://user:pass@host/db
  # or Unix peer auth (NixOS / local socket — no password):
  #   DATABASE_SOCKET_DIR=/run/postgresql
  #   DATABASE_USER=earss
  #   DATABASE_NAME=earss
  #
  # Postgrex docs: use :socket_dir (directory containing .s.PGSQL.5432).
  # Do NOT put the socket path in :hostname — that is treated as a TCP host
  # and yields nxdomain (see https://hexdocs.pm/postgrex/Postgrex.html).
  # ---------------------------------------------------------------------------

  socket_repo_opts =
    case fetch_str.("DATABASE_SOCKET_DIR") do
      {:ok, socket_dir} ->
        [
          username: env.("DATABASE_USER") || "earss",
          database: env.("DATABASE_NAME") || "earss",
          # Preferred Unix-socket option (takes precedence over :hostname)
          socket_dir: socket_dir,
          # Peer auth does not use a password; empty string satisfies the key
          # if the server still offers SCRAM on some paths.
          password: env.("DATABASE_PASSWORD") || ""
        ]

      :unset ->
        nil
    end

  url_repo_opts =
    case fetch_str.("DATABASE_URL") do
      {:ok, url} -> [url: url]
      :unset -> nil
    end

  # Socket mode wins when both are set (homeserver peer auth).
  base_repo_opts = socket_repo_opts || url_repo_opts || []

  repo_opts =
    case fetch_int.("POOL_SIZE") do
      {:ok, n} -> Keyword.put(base_repo_opts, :pool_size, n)
      :unset -> base_repo_opts
    end

  # Sensible prod default when DB is configured
  repo_opts =
    if config_env() == :prod and repo_opts != [] and is_nil(Keyword.get(repo_opts, :pool_size)) do
      Keyword.put(repo_opts, :pool_size, 10)
    else
      repo_opts
    end

  if repo_opts != [] do
    config :earss, Earss.Repo, repo_opts
  end

  if config_env() == :prod and repo_opts == [] do
    raise """
    database is not configured for production.

    Set either:
      DATABASE_URL=ecto://USER:PASS@HOST/DATABASE
    or Unix socket peer auth:
      DATABASE_SOCKET_DIR=/run/postgresql
      DATABASE_USER=earss
      DATABASE_NAME=earss
    """
  end

  # ---------------------------------------------------------------------------
  # HTTP API
  # ---------------------------------------------------------------------------

  api_opts = []

  api_opts =
    case fetch_bool.("API_ENABLED") do
      {:ok, v} -> Keyword.put(api_opts, :enabled, v)
      :unset -> api_opts
    end

  api_opts =
    case fetch_int.("PORT") do
      {:ok, n} -> Keyword.put(api_opts, :port, n)
      :unset -> api_opts
    end

  api_opts =
    case fetch_int.("TOKEN_MAX_AGE_SECS") do
      {:ok, n} -> Keyword.put(api_opts, :token_max_age_secs, n)
      :unset -> api_opts
    end

  api_opts =
    case fetch_bool.("HTTP_COOKIE_SECURE") do
      {:ok, v} -> Keyword.put(api_opts, :cookie_secure, v)
      :unset -> api_opts
    end

  api_opts =
    case {fetch_str.("SECRET_KEY_BASE"), config_env()} do
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
    case fetch_bool.("POLLER_ENABLED") do
      {:ok, v} -> Keyword.put(poller_opts, :enabled, v)
      :unset -> poller_opts
    end

  poller_opts =
    case fetch_int.("POLLER_INTERVAL_MS") do
      {:ok, n} -> Keyword.put(poller_opts, :interval_ms, n)
      :unset -> poller_opts
    end

  poller_opts =
    case fetch_int.("POLLER_BATCH_SIZE") do
      {:ok, n} -> Keyword.put(poller_opts, :batch_size, n)
      :unset -> poller_opts
    end

  poller_opts =
    case fetch_int.("POLLER_MAX_CONCURRENCY") do
      {:ok, n} -> Keyword.put(poller_opts, :max_concurrency, n)
      :unset -> poller_opts
    end

  poller_opts =
    case fetch_int.("POLLER_INITIAL_DELAY_MS") do
      {:ok, n} -> Keyword.put(poller_opts, :initial_delay_ms, n)
      :unset -> poller_opts
    end

  poller_opts =
    case fetch_int.("POLLER_TIMEOUT_MS") do
      {:ok, n} -> Keyword.put(poller_opts, :timeout_ms, n)
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
    case fetch_int.("RETENTION_READ_STATE_DAYS") do
      {:ok, n} -> Keyword.put(retention_opts, :read_state_days, n)
      :unset -> retention_opts
    end

  retention_opts =
    case fetch_int.("RETENTION_ENTRY_DAYS") do
      {:ok, n} -> Keyword.put(retention_opts, :entry_days, n)
      :unset -> retention_opts
    end

  retention_opts =
    case fetch_int.("RETENTION_UNSUBSCRIBED_FEED_DAYS") do
      {:ok, n} -> Keyword.put(retention_opts, :unsubscribed_feed_days, n)
      :unset -> retention_opts
    end

  if retention_opts != [] do
    config :earss, :retention, retention_opts
  end

  ret_poller_opts = []

  ret_poller_opts =
    case fetch_bool.("RETENTION_POLLER_ENABLED") do
      {:ok, v} -> Keyword.put(ret_poller_opts, :enabled, v)
      :unset -> ret_poller_opts
    end

  ret_poller_opts =
    case fetch_int.("RETENTION_POLLER_INTERVAL_MS") do
      {:ok, n} -> Keyword.put(ret_poller_opts, :interval_ms, n)
      :unset -> ret_poller_opts
    end

  ret_poller_opts =
    case fetch_int.("RETENTION_BATCH_SIZE") do
      {:ok, n} -> Keyword.put(ret_poller_opts, :batch_size, n)
      :unset -> ret_poller_opts
    end

  ret_poller_opts =
    case fetch_int.("RETENTION_INITIAL_DELAY_MS") do
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
    case fetch_int.("REFRESH_MIN_INTERVAL") do
      {:ok, n} -> Keyword.put(refresh_opts, :min_interval, n)
      :unset -> refresh_opts
    end

  refresh_opts =
    case fetch_int.("REFRESH_MAX_INTERVAL") do
      {:ok, n} -> Keyword.put(refresh_opts, :max_interval, n)
      :unset -> refresh_opts
    end

  refresh_opts =
    case fetch_int.("REFRESH_DEFAULT_INTERVAL") do
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
    case fetch_int.("HTTP_RECEIVE_TIMEOUT_MS") do
      {:ok, n} -> Keyword.put(http_opts, :receive_timeout, n)
      :unset -> http_opts
    end

  http_opts =
    case fetch_str.("HTTP_USER_AGENT") do
      {:ok, ua} -> Keyword.put(http_opts, :user_agent, ua)
      :unset -> http_opts
    end

  if http_opts != [] do
    config :earss, :http, http_opts
  end

  # ---------------------------------------------------------------------------
  # Per-host crawl politeness
  # ---------------------------------------------------------------------------

  politeness_opts = []

  politeness_opts =
    case fetch_bool.("HOST_POLITENESS_ENABLED") do
      {:ok, v} -> Keyword.put(politeness_opts, :enabled, v)
      :unset -> politeness_opts
    end

  politeness_opts =
    case fetch_int.("HOST_MAX_CONCURRENT") do
      {:ok, n} -> Keyword.put(politeness_opts, :max_concurrent_per_host, n)
      :unset -> politeness_opts
    end

  politeness_opts =
    case fetch_int.("HOST_MIN_INTERVAL_MS") do
      {:ok, n} -> Keyword.put(politeness_opts, :min_interval_ms, n)
      :unset -> politeness_opts
    end

  politeness_opts =
    case fetch_int.("HOST_DEFAULT_COOLDOWN_MS") do
      {:ok, n} -> Keyword.put(politeness_opts, :default_cooldown_ms, n)
      :unset -> politeness_opts
    end

  politeness_opts =
    case fetch_int.("HOST_CHECKOUT_TIMEOUT_MS") do
      {:ok, n} -> Keyword.put(politeness_opts, :checkout_timeout_ms, n)
      :unset -> politeness_opts
    end

  if politeness_opts != [] do
    config :earss, :host_politeness, politeness_opts
  end

  # ---------------------------------------------------------------------------
  # Content enrichment / translation
  # ---------------------------------------------------------------------------

  translate_opts = []

  translate_opts =
    case fetch_int.("TRANSLATE_MAX_CONCURRENCY") do
      {:ok, n} when n > 0 -> Keyword.put(translate_opts, :max_concurrency, n)
      _ -> translate_opts
    end

  translate_opts =
    case fetch_int.("TRANSLATE_PENDING_WORKER_INTERVAL_MS") do
      {:ok, n} when n > 0 ->
        Keyword.put(translate_opts, :pending_worker, %{interval_ms: n})

      _ ->
        translate_opts
    end

  translate_opts =
    case fetch_int.("TRANSLATE_MAX_PENDING_RETRIES") do
      {:ok, n} when n > 0 -> Keyword.put(translate_opts, :max_pending_retries, n)
      _ -> translate_opts
    end

  if translate_opts != [] do
    config :earss, :translate, translate_opts
  end

  # ---------------------------------------------------------------------------
  # Inbound rate limiting (Earss.RateLimit) — auth brute-force protection
  # ---------------------------------------------------------------------------

  # X-Forwarded-For is honoured only when the direct peer is inside these
  # CIDRs. Behind Tailscale Funnel the proxy lives in the tailnet CGNAT
  # range: EARSS_RATE_LIMIT_TRUSTED_PROXIES=100.64.0.0/10
  rate_limit_opts = []

  rate_limit_opts =
    case fetch_str.("EARSS_RATE_LIMIT_TRUSTED_PROXIES") do
      {:ok, raw} ->
        Keyword.put(
          rate_limit_opts,
          :trusted_proxies,
          raw |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
        )

      :unset ->
        rate_limit_opts
    end

  if rate_limit_opts != [] do
    config :earss, :rate_limit, rate_limit_opts
  end

  # ---------------------------------------------------------------------------
  # Bootstrap default admin (empty users table only)
  # ---------------------------------------------------------------------------

  boot_opts = []

  boot_opts =
    case fetch_bool.("EARSS_BOOTSTRAP_ADMIN") do
      {:ok, v} -> Keyword.put(boot_opts, :enabled, v)
      :unset -> boot_opts
    end

  boot_opts =
    case fetch_str.("EARSS_DEFAULT_ADMIN_USER") do
      {:ok, u} -> Keyword.put(boot_opts, :username, u)
      :unset -> boot_opts
    end

  boot_opts =
    case fetch_str.("EARSS_DEFAULT_ADMIN_PASSWORD") do
      {:ok, p} -> Keyword.put(boot_opts, :password, p)
      :unset -> boot_opts
    end

  if boot_opts != [] do
    config :earss, :bootstrap_admin, boot_opts
  end

  # ---------------------------------------------------------------------------
  # Listen-later controls (TTS intent capture) — Earss.API.ListenControls
  # ---------------------------------------------------------------------------

  # Injects a "listen" control into article content; clicking it records the
  # listen request. Needs an absolute public base URL — feed content cannot
  # use relative hrefs, so without one injection stays off.
  tts_opts = []

  tts_opts =
    case fetch_bool.("EARSS_TTS_LISTEN_CONTROLS") do
      {:ok, v} -> Keyword.put(tts_opts, :listen_controls, v)
      :unset -> tts_opts
    end

  tts_opts =
    case fetch_str.("EARSS_TTS_PUBLIC_URL") do
      {:ok, url} -> Keyword.put(tts_opts, :public_url, String.trim_trailing(url, "/"))
      :unset -> tts_opts
    end

  tts_opts =
    case fetch_str.("EARSS_TTS_AUDIO_DIR") do
      {:ok, dir} -> Keyword.put(tts_opts, :audio_dir, dir)
      :unset -> tts_opts
    end

  tts_opts =
    case fetch_bool.("EARSS_TTS_WORKER_ENABLED") do
      {:ok, v} -> Keyword.update(tts_opts, :worker, [enabled: v], &Keyword.put(&1, :enabled, v))
      :unset -> tts_opts
    end

  tts_opts =
    case fetch_int.("EARSS_TTS_MAX_CONCURRENCY") do
      {:ok, n} when n > 0 -> Keyword.put(tts_opts, :max_concurrency, n)
      _ -> tts_opts
    end

  tts_opts =
    case fetch_int.("EARSS_TTS_WORKER_INTERVAL_MS") do
      {:ok, n} when n > 0 ->
        Keyword.update(tts_opts, :worker, [interval_ms: n], &Keyword.put(&1, :interval_ms, n))

      _ ->
        tts_opts
    end

  tts_opts =
    case fetch_int.("EARSS_TTS_MAX_RETRIES") do
      {:ok, n} when n >= 0 ->
        Keyword.update(tts_opts, :worker, [max_retries: n], &Keyword.put(&1, :max_retries, n))

      _ ->
        tts_opts
    end

  if tts_opts != [] do
    # Deep-merge into the compiled :tts config instead of replacing it:
    # config.exs carries the nested worker defaults (batch_size,
    # processing_lease_secs, provider_opts, …) and a bare replace would
    # drop them the moment the operator sets any EARSS_TTS_* variable.
    merged =
      Keyword.merge(Application.get_env(:earss, :tts, []), tts_opts, fn _k, base, override ->
        if Keyword.keyword?(base) and Keyword.keyword?(override) do
          Keyword.merge(base, override)
        else
          override
        end
      end)

    config :earss, :tts, merged
  end
end
