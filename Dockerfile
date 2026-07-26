# Earss production image (Mix release).
#
# Build (stock RSS only):
#   docker build -t earss:local .
#
# Build with optional source plugins (compile-time):
#   docker build -t earss:local \
#     --build-arg EARSS_SOURCE_PLUGINS='github:ll1zt/earss_source_telegram@main' .
#
# Prefer docker compose (see docker-compose.yml + docs/docker.md).

# ---------------------------------------------------------------------------
# Builder
# ---------------------------------------------------------------------------
# Official image: Elixir 1.18 + OTP 27 on Debian slim (matches mix.exs ~> 1.18).
FROM elixir:1.18.4-otp-27-slim AS builder

# Optional Mix deps — free-form EARSS_SOURCE_PLUGINS grammar (see mix.exs).
ARG EARSS_SOURCE_PLUGINS=""
ENV EARSS_SOURCE_PLUGINS=${EARSS_SOURCE_PLUGINS}

RUN apt-get update -y \
  && apt-get install -y --no-install-recommends build-essential git ca-certificates \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

ENV MIX_ENV=prod \
    LANG=C.UTF-8

RUN mix local.hex --force && mix local.rebar --force

# Deps layer (cache-friendly): lock + mix files first.
COPY mix.exs mix.lock ./
COPY config config
COPY packages/earss_source packages/earss_source

RUN mix deps.get --only prod \
  && mix deps.compile

# Application source
COPY lib lib
COPY priv priv

RUN mix compile \
  && mix release

# ---------------------------------------------------------------------------
# Runtime
# ---------------------------------------------------------------------------
FROM debian:bookworm-slim AS runner

RUN apt-get update -y \
  && apt-get install -y --no-install-recommends \
    libstdc++6 \
    openssl \
    libncurses6 \
    locales \
    ca-certificates \
    curl \
  && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
  && locale-gen \
  && rm -rf /var/lib/apt/lists/* \
  && groupadd --system --gid 1000 earss \
  && useradd --system --uid 1000 --gid earss --home /app --shell /usr/sbin/nologin earss

WORKDIR /app

ENV MIX_ENV=prod \
    LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8 \
    HOME=/app \
    RELEASE_TMP=/tmp/earss \
    PORT=4000

COPY --from=builder --chown=earss:earss /app/_build/prod/rel/earss ./
COPY --chown=earss:earss docker/entrypoint.sh /app/entrypoint.sh

RUN chmod +x /app/entrypoint.sh \
  && mkdir -p /tmp/earss \
  && chown -R earss:earss /tmp/earss

USER earss

EXPOSE 4000

# App listens on PORT (default 4000); health path is always /health.
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD curl -fsS http://127.0.0.1:4000/health >/dev/null || exit 1

ENTRYPOINT ["/app/entrypoint.sh"]
