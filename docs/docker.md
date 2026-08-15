# Docker / Compose deployment

> 📖 Choosing a deployment path: [User guide → Install](usage.md) · [deploy.md](deploy.md) · [nixos.md](nixos.md).

Self-host Earss with **Docker Compose**: PostgreSQL + Mix release image.

For bare-metal Mix release / systemd see [deploy.md](deploy.md).  
For declarative NixOS see [nixos.md](nixos.md).

## What you get

| Service | Image / role |
|---------|----------------|
| `db` | `postgres:16-alpine` — app data (`citext` created by migrations) |
| `earss` | Multi-stage build of this repo — migrate on start, Bandit on `:4000` |

Endpoints after `docker compose up`:

| Path | Role |
|------|------|
| `/health` | Liveness |
| `/admin` | Web admin |
| `/api/*` | JSON API |
| `/fever/` | Fever (NetNewsWire) |
| `/api/greader.php` | FreshRSS / GReader |

## Requirements

- Docker Engine with Compose v2 (`docker compose`)
- ~1–2 GB free RAM for first image build (Elixir + OTP compile)
- Outbound network during **build** if you pin source plugins from GitHub

## Quick start

```bash
git clone <repo-url> earss && cd earss

cp .env.docker.example .env
# Required:
#   SECRET_KEY_BASE=$(openssl rand -base64 48)
# edit .env and paste SECRET_KEY_BASE=

docker compose up -d --build
```

Open **http://localhost:4000/admin**

Single-operator mode: set the operator credentials in `.env` before first
boot (unset credentials reject every login):

```env
ADMIN_PASSWORD=<a strong password>
FEVER_API_KEY=<random hex for NetNewsWire Fever>
```

### Logs

```bash
docker compose logs -f earss
docker compose logs -f db
```

### Stop / start

```bash
docker compose down          # keeps volume earss_pgdata
docker compose down -v       # DESTROYS the database volume
docker compose up -d
```

## Configuration

Compose reads project-root **`.env`** for substitution (see [`.env.docker.example`](../.env.docker.example)).

| Variable | When | Notes |
|----------|------|--------|
| `SECRET_KEY_BASE` | **Required** | `openssl rand -base64 48` |
| `POSTGRES_*` | Runtime | User / password / DB name for the `db` service |
| `PORT` | Host only | Host port mapped to container `4000` (default `4000`) |
| `EARSS_SOURCE_PLUGINS` | **Build** | Same grammar as `mix.exs` / `earss.env.example` |
| `EARSS_DEFAULT_ADMIN_*` | First boot | Only if `users` is empty |
| `POOL_SIZE`, `POLLER_*`, `HOST_*` | Runtime | Passed into the app container |

Full runtime key list: [`earss.env.example`](../earss.env.example).

### Plugins

Plugins are **compile-time** Mix dependencies. Set before build:

```bash
# in .env
EARSS_SOURCE_PLUGINS=github:ll1zt/earss_source_telegram@main
```

```bash
docker compose build --no-cache earss
docker compose up -d
```

Changing plugins without rebuild has no effect. Prefer pinning a commit SHA instead of floating `@main` for reproducible images.

## Build only (no Compose)

```bash
docker build -t earss:local .
# with plugins:
docker build -t earss:local \
  --build-arg EARSS_SOURCE_PLUGINS='github:ll1zt/earss_source_telegram@main' .
```

Run against an existing Postgres:

```bash
docker run --rm -p 4000:4000 \
  -e DATABASE_URL='ecto://earss:SECRET@host.docker.internal/earss' \
  -e SECRET_KEY_BASE='…' \
  earss:local
```

The image entrypoint always runs `Earss.Release.migrate()` before `start`.

## Data & backups

Postgres data lives in the Compose volume **`earss_pgdata`**.

Dump example:

```bash
docker compose exec -T db \
  pg_dump -U earss -d earss --format=custom \
  > earss-$(date +%Y%m%d).dump
```

Restore (service stopped or DB empty as appropriate):

```bash
docker compose exec -T db \
  pg_restore -U earss -d earss --clean --if-exists \
  < earss-YYYYMMDD.dump
```

Also see [backup.md](backup.md).

## Upgrade

1. `git pull` (or rebuild from a new tag).
2. Optional: dump DB first.
3. Rebuild and recreate:

```bash
docker compose build earss
docker compose up -d
```

Migrations run automatically on container start.

## Reverse proxy

Publish only via reverse proxy / VPN in production. Example Caddy:

```caddy
rss.example.com {
  reverse_proxy 127.0.0.1:4000
}
```

Restrict `/admin` (VPN-only, extra auth, or firewall) when the instance is public.

## Architecture of the image

```text
Dockerfile
  builder: elixir:1.18.4-otp-27-slim
    mix deps.get → compile → mix release
  runner:  debian:bookworm-slim
    non-root user earss (uid 1000)
    entrypoint: migrate → bin/earss start
```

| Path in image | Role |
|---------------|------|
| `/app/bin/earss` | Release CLI (`start`, `eval`, `remote`, …) |
| `/app/entrypoint.sh` | Migrate then start |
| `RELEASE_TMP=/tmp/earss` | BEAM temp / cookie |

Healthcheck: `GET /health` on `PORT` (default 4000).

## Troubleshooting

| Symptom | Check |
|---------|--------|
| Compose exits on start: missing `SECRET_KEY_BASE` | Set it in `.env` |
| `earss` restarts: DB connection | `docker compose ps` / `logs db`; wait for healthy `db` |
| Extension / migration errors | App user must be DB owner (default Compose setup is fine); `citext` is created in migrations |
| Plugin adapter missing at runtime | Rebuild with `EARSS_SOURCE_PLUGINS`; plugins are not installable at runtime |
| Slow first build | Normal (compile NIFs + deps); later builds cache Docker layers |
| Apple Silicon / amd64 | Image builds for the host arch; multi-arch publish is optional CI work |

```bash
# Shell into the app container
docker compose exec earss sh

# Manual migrate (usually unnecessary — entrypoint does this)
docker compose exec earss /app/bin/earss eval "Earss.Release.migrate()"

# Remote IEx (if you need it)
docker compose exec earss /app/bin/earss remote
```

## Related

- [deploy.md](deploy.md) — systemd / bare release  
- [nixos.md](nixos.md) — Nix flake module  
- [backup.md](backup.md) — dump/restore  
- [sources.md](sources.md) — plugins  
