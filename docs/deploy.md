# Deploy

Self-host Earss as a **Mix release** behind systemd (or equivalent).  
Recommended on **NixOS homeservers**: host PostgreSQL + release unit + reverse proxy / Tailscale.

There is no official container image yet; Docker is optional (see [Alternatives](#alternatives)).

## What you need

| Piece | Notes |
|-------|--------|
| **PostgreSQL** | Same major as you develop against; role must `CREATE EXTENSION citext` once |
| **Elixir / OTP** | Only on the **build** machine (`~> 1.18`); runtime is the release ERTS |
| **Secrets** | `DATABASE_URL`, `SECRET_KEY_BASE` (required in prod) |
| **Optional plugins** | Must be present at **`mix deps.get` / release build** via `EARSS_SOURCE_PLUGINS` |

State lives in PostgreSQL. Backup story: [backup.md](backup.md).

## Build a release

On a machine with matching **OS / CPU arch** to the target (NIFs: `argon2_elixir`):

```bash
git clone <repo-url> earss && cd earss

# Optional: pin source plugins into the release
export EARSS_SOURCE_PLUGINS='github:ll1zt/earss_source_telegram@main'
# or copy earss.env with EARSS_SOURCE_PLUGINS=... before deps.get

MIX_ENV=prod mix deps.get --only prod
MIX_ENV=prod mix compile
MIX_ENV=prod mix release
```

Artifact:

```text
_build/prod/rel/earss/
  bin/earss          # start | stop | restart | eval | remote
  ...
```

Copy that directory to the server (e.g. `/var/lib/earss/rel`) or install via Nix.

### Plugins

| Time | Variable | Effect |
|------|----------|--------|
| **Build** | `EARSS_SOURCE_PLUGINS` | Mix deps compiled into the release |
| **Runtime** | (none for install) | Adapters register at boot if the app is in the release |
| **Runtime** | `EARSS_SOURCE_ADAPTERS` | Extra module list if discovery is not enough |

Changing plugins ⇒ **rebuild** the release. Do not run `mix deps.get` on the production host.

## Runtime environment

Prod **requires**:

```bash
DATABASE_URL=ecto://earss:SECRET@127.0.0.1/earss
SECRET_KEY_BASE=   # openssl rand -base64 48
```

Common optional keys (full list: [`earss.env.example`](../earss.env.example)):

| Variable | Purpose |
|----------|---------|
| `PORT` | Bandit listen port (default `4000`) |
| `POOL_SIZE` | Repo pool (default `10` in prod when only URL is set) |
| `POLLER_*` | Feed poller |
| `HOST_*` | Per-host crawl politeness |
| `RETENTION_*` | Cleanup windows / poller |
| `HTTP_USER_AGENT` | Outbound fetch UA |

**How env is loaded** (`config/runtime.exs`):

1. Process environment (systemd `EnvironmentFile=`, Docker, shell) — highest priority for already-set keys  
2. Optional files (do not override existing process env):  
   - project `earss.env` / `earss.env.local` (source checkouts)  
   - `$RELEASE_ROOT/earss.env`  
   - `$EARSS_ENV_DIR/earss.env`

Prefer **systemd EnvironmentFile** or **sops/agenix** over shipping secrets next to the binary.

## Database bootstrap

```bash
# As a Postgres superuser (once per cluster/DB):
sudo -u postgres psql -c "CREATE USER earss WITH PASSWORD '…';"
sudo -u postgres psql -c "CREATE DATABASE earss OWNER earss;"
sudo -u postgres psql -d earss -c "CREATE EXTENSION IF NOT EXISTS citext;"
```

Migrate and create the first admin (release must see `DATABASE_URL`):

```bash
export DATABASE_URL='ecto://earss:…@127.0.0.1/earss'
export SECRET_KEY_BASE='…'

/var/lib/earss/rel/bin/earss eval "Earss.Release.migrate()"
/var/lib/earss/rel/bin/earss eval 'Earss.Release.seed_admin("admin", "change-me")'
```

`seed_admin/2` is idempotent (`{:ok, :exists}` if the username is taken).

## Run

Foreground (debug):

```bash
/var/lib/earss/rel/bin/earss start
```

Endpoints (default port 4000):

| Path | Role |
|------|------|
| `/health` | Liveness |
| `/admin` | Web admin — restrict exposure |
| `/api/*` | JSON API |
| `/fever/` | Fever (NetNewsWire) |
| `/api/greader.php` | FreshRSS / GReader (NetNewsWire) |

## systemd (generic)

```ini
[Unit]
Description=Earss feed reader
After=network-online.target postgresql.service
Wants=network-online.target
Requires=postgresql.service

[Service]
Type=exec
User=earss
Group=earss
WorkingDirectory=/var/lib/earss
EnvironmentFile=/etc/earss/earss.env
ExecStartPre=/var/lib/earss/rel/bin/earss eval "Earss.Release.migrate()"
ExecStart=/var/lib/earss/rel/bin/earss start
ExecStop=/var/lib/earss/rel/bin/earss stop
Restart=on-failure
RestartSec=5

NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=/var/lib/earss
# If the release needs to write tmp/logs under RELEASE_ROOT, keep that path writable.

[Install]
WantedBy=multi-user.target
```

`earss.env` example:

```bash
DATABASE_URL=ecto://earss:SECRET@127.0.0.1/earss
SECRET_KEY_BASE=…
PORT=4000
POOL_SIZE=5
POLLER_MAX_CONCURRENCY=3
HOST_MAX_CONCURRENT=2
HOST_MIN_INTERVAL_MS=1000
```

## NixOS (homeserver-oriented)

Recommended shape: **declarative PostgreSQL + release binary + systemd**, optional Caddy/nginx, secrets via **agenix** or **sops-nix**.

### Minimal sketch

Not a full flake package — drop into your host config and point `earssRelease` at a built release path or a flake package you maintain:

```nix
# users + postgres
users.users.earss = {
  isSystemUser = true;
  group = "earss";
  home = "/var/lib/earss";
  createHome = true;
};
users.groups.earss = { };

services.postgresql = {
  enable = true;
  ensureDatabases = [ "earss" ];
  ensureUsers = [{
    name = "earss";
    ensureDBOwnership = true;
  }];
};

# One-shot or activation script: CREATE EXTENSION citext;
# (ensureUsers does not install extensions.)

age.secrets.earss-env = {
  file = ../secrets/earss-env.age;
  owner = "earss";
};

systemd.services.earss = {
  description = "Earss feed reader";
  after = [ "network-online.target" "postgresql.service" ];
  wants = [ "network-online.target" ];
  requires = [ "postgresql.service" ];
  wantedBy = [ "multi-user.target" ];
  serviceConfig = {
    Type = "exec";
    User = "earss";
    Group = "earss";
    WorkingDirectory = "/var/lib/earss";
    EnvironmentFile = config.age.secrets.earss-env.path;
    ExecStartPre = "${earssRelease}/bin/earss eval \"Earss.Release.migrate()\"";
    ExecStart = "${earssRelease}/bin/earss start";
    ExecStop = "${earssRelease}/bin/earss stop";
    Restart = "on-failure";
    RestartSec = "5s";
    NoNewPrivileges = true;
    PrivateTmp = true;
  };
};
```

### Packaging notes

- Prefer building the release **inside Nix** (`beamPackages.mixRelease` or a fixed-output derivation) so the ERTS and NIFs match `system`.  
- Build-time `EARSS_SOURCE_PLUGINS` should be a **fixed flake input / hash**, not a floating `@main` in production.  
- Keep `SECRET_KEY_BASE` stable across rebuilds or all sessions/tokens invalidate.  
- Backups: timer on `pg_dump` + secret store; see [backup.md](backup.md).

### Exposure

| Approach | Fit |
|----------|-----|
| **Tailscale only** (`PORT` on tailnet IP) | Best default for homeserver + phone NNW |
| **Caddy / nginx** TLS reverse proxy | Public or LAN HTTPS |
| Restrict `/admin` | Extra auth, VPN-only, or firewall | 

Example Caddy snippet:

```caddy
rss.example.com {
  reverse_proxy 127.0.0.1:4000
}
```

## Upgrade

1. Build a new release (same plugin pins unless intentional).  
2. `pg_dump` first ([backup.md](backup.md)).  
3. Replace release directory / switch Nix generation.  
4. `Earss.Release.migrate()` (or `ExecStartPre`).  
5. Start service; smoke-check `/health` and one client sync.

Rollback: previous release directory or previous NixOS generation + DB restore if migrations were unsafe (prefer additive migrations).

## Resource ballpark (home)

- Single-user / family: **512MB–1GB** RAM for BEAM + shared Postgres is usually enough  
- Lower `POOL_SIZE`, `POLLER_MAX_CONCURRENCY`, and rely on host politeness defaults on small uplinks  

## Alternatives

| Mode | When |
|------|------|
| **Docker / Podman** | Same release binary in a distroless/debian image; still need Postgres |
| **`iex -S mix` / `mix` on server** | Dev only — not for production |
| **Full NixOS module in-tree** | Optional future; this doc stays distribution-agnostic |

## Related

- [development.md](development.md) — local setup  
- [backup.md](backup.md) — dump/restore  
- [architecture.md](architecture.md) — runtime processes  
- [sources.md](sources.md) — plugins  
