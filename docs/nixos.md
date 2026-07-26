# Declarative NixOS deployment

This repository ships:

| Path | Role |
|------|------|
| [`flake.nix`](../flake.nix) | `packages.earss` (Mix release) + `nixosModules.earss` |
| [`nix/package.nix`](../nix/package.nix) | `mixRelease` derivation |
| [`nix/module.nix`](../nix/module.nix) | `services.earss.*` |
| [deploy.md](deploy.md) | Generic release / systemd (non-Nix) |

**Target:** a NixOS homeserver with local PostgreSQL, systemd, and optional Tailscale/Caddy.

---

## Architecture

```text
your-host-flake
  inputs.earss → this repo
       │
       ├─ packages.<system>.earss     # Mix release (bin/earss)
       └─ nixosModules.earss
              │
              services.earss.enable = true
              ├── user earss + /var/lib/earss
              ├── postgresql (optional createLocally)
              ├── citext oneshot
              ├── systemd earss.service (migrate + start)
              └── optional nginx vhost
```

Secrets stay out of the world-readable Nix store: use **agenix**, **sops-nix**, or `pkgs.writeText` only for throwaway VMs.

---

## 1. Build the package once (fill `mixDepsHash`)

On a Linux builder (same arch as the server: `x86_64-linux` or `aarch64-linux`):

```bash
cd /path/to/earss

# First attempt will fail with a hash mismatch — that is expected.
nix build .#earss --print-build-logs
```

Copy the `got: sha256-…` value into `flake.nix` → `mixDepsHash`, then rebuild:

```bash
nix build .#earss
./result/bin/earss   # should print usage / subcommands
```

### Optional plugins (build-time)

Edit `flake.nix`:

```nix
sourcePlugins = "github:ll1zt/earss_source_telegram@a07fe0b947f0dcabc61d40ff85449ebb461ba04e";
# then re-run nix build, update mixDepsHash again
```

Floating `@main` will break the fixed-output deps hash whenever the branch moves — **pin a commit**.

### Cross-arch note

Build on the same architecture as the homeserver (or use a remote Linux builder).  
`argon2_elixir` ships a NIF; a macOS-built release will not run on Linux.

---

## Plugins (optional, compile into the release)

Plugins are **not** installed by changing only runtime env on the server.
They must be present when the Mix release is built (`EARSS_SOURCE_PLUGINS` /
flake `sourcePlugins`), then the new package is deployed.

| Want | Do |
|------|-----|
| Stock RSS / Atom / JSON only | `sourcePlugins = ""` |
| RSSHub-backed feeds | `http://…:1200/…` as normal HTTPS — **no plugin** |
| Telegram + Zhihu + Viva | Current default in `flake.nix` `sourcePlugins` (pinned commits) |

### Install / upgrade the three reference plugins

`flake.nix` pins (update commits as needed):

```text
github:ll1zt/earss_source_telegram@…
github:ll1zt/earss_source_zhihu@…
github:ll1zt/earss_source_viva-la-vita@…
```

On **x86_64-linux**:

```bash
cd /path/to/earss
nix build .#earss --print-build-logs
# paste got: sha256-… into mixDepsHash
nix build .#earss   # confirm
git commit -am "nix: plugins + mixDepsHash" && git push
```

On the homeserver:

```bash
cd ~/nix-config
nix flake update earss
just nixos-rebuild
```

Check Admin → **Sources** for adapters `telegram`, `zhihu`, `viva-la-vita`.

### Subscribe URLs

| Plugin | Example |
|--------|---------|
| Telegram | `earss://telegram/channel/<username>` |
| Viva | `earss://viva-la-vita/latest/new` or `earss://viva-la-vita/d/<id>` |
| Zhihu | `earss://zhihu/people/answers/<url_token>` etc. |

### Zhihu runtime secrets (`/etc/secrets/earss.env`)

Required for Zhihu fetches (not for building the release):

```bash
# CookieCloud (recommended if you already run cookie-cloud on :4000)
EARSS_ZHIHU_COOKIE_CLOUD_URL=http://127.0.0.1:4000
EARSS_ZHIHU_COOKIE_CLOUD_UUID=your-uuid
EARSS_ZHIHU_COOKIE_CLOUD_TOKEN=same-as-COOKIE_CLOUD_SERVER_PASSWORD

# OR static cookies (must include d_c0=)
# EARSS_ZHIHU_COOKIES='d_c0=...; z_c0=...'
```

Telegram and viva-la-vita need no extra env for public content.

There is no safe “download plugin at runtime into the Nix store” path without
building a new release (or a non-Nix packaging model).

## 2. Wire into your host flake

```nix
# flake.nix (host)
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    earss.url = "github:ll1zt/earss"; # or path:/home/you/earss
    # earss.inputs.nixpkgs.follows = "nixpkgs"; # optional alignment
    agenix.url = "github:ryantm/agenix";
  };

  outputs = { self, nixpkgs, earss, agenix, ... }: {
    nixosConfigurations.homeserver = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux"; # or aarch64-linux
      modules = [
        ./hosts/homeserver/configuration.nix
        earss.nixosModules.earss
        agenix.nixosModules.default
      ];
    };
  };
}
```

---

## 3. Host module (`configuration.nix`)

### Minimal (local Postgres + peer auth + agenix secret)

```nix
{ config, pkgs, inputs, ... }:
{
  # --- secrets (agenix example) ---
  # secrets/earss-secret-key-base.age decrypts to a single line (openssl rand -base64 48)
  age.secrets.earss-skb = {
    file = ../secrets/earss-secret-key-base.age;
    owner = "earss";
    group = "earss";
  };

  services.earss = {
    enable = true;
    package = inputs.earss.packages.${pkgs.system}.earss;

    # SECRET_KEY_BASE from file (loaded via systemd credentials)
    secretKeyBaseFile = config.age.secrets.earss-skb.path;

    port = 4000;
    openFirewall = false; # use Tailscale / reverse proxy

    # Local PG + role "earss" + citext; DATABASE_URL uses Unix socket peer auth
    database = {
      createLocally = true;
      name = "earss";
      user = "earss"; # must match services.earss.user for peer auth
    };

    # Non-secret tuning
    settings = {
      POOL_SIZE = "5";
      POLLER_MAX_CONCURRENCY = "3";
      HOST_MAX_CONCURRENT = "2";
      HOST_MIN_INTERVAL_MS = "1000";
    };

    migrateOnStart = true;
  };

  # Optional: only on the tailnet interface, or use Tailscale Serve/Funnel
  # networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ 4000 ];
}
```

Deploy:

```bash
sudo nixos-rebuild switch --flake .#homeserver
```

### First admin user

After the service is enabled (migrations run on start), seed once:

```bash
# Resolve the release binary from the unit
EARSS_BIN="$(systemctl show -p FragmentPath earss | cut -d= -f2 | xargs dirname)/.." # fragile

# Prefer the store path from nixos-option / your flake:
#   nix eval .#nixosConfigurations.homeserver.config.services.earss.package
EARSS_BIN=/nix/store/…-earss-0.1.0/bin/earss

# Stop the service first. `sudo -u earss` from /home/* leaves cwd unreadable
# for user earss and crashes BEAM (code_server/logger badarg).
sudo systemctl stop earss
EARSS_BIN=$(systemctl cat earss | grep -oE '/nix/store/[^ ]+-earss-[0-9][^ ]*/bin/earss' | head -1)
sudo install -d -o earss -g earss /var/lib/earss/tmp
sudo --chdir=/var/lib/earss -u earss env \
  HOME=/var/lib/earss \
  RELEASE_COOKIE=earss_service \
  RELEASE_DISTRIBUTION=none \
  RELEASE_TMP=/var/lib/earss/tmp \
  DATABASE_SOCKET_DIR=/run/postgresql \
  DATABASE_USER=earss \
  DATABASE_NAME=earss \
  SECRET_KEY_BASE="$(grep -E '^SECRET_KEY_BASE=' /etc/secrets/earss.env | cut -d= -f2-)" \
  "$EARSS_BIN" eval 'Earss.Release.seed_admin("admin", "change-me")'
sudo systemctl start earss
```

**Simpler:** one env file with `SECRET_KEY_BASE` (and optional overrides), no `secretKeyBaseFile`:

```nix
age.secrets.earss-env = {
  file = ../secrets/earss-env.age;
  owner = "earss";
};

services.earss = {
  enable = true;
  package = inputs.earss.packages.${pkgs.system}.earss;
  environmentFile = config.age.secrets.earss-env.path;
  database.createLocally = true;
};
```

`earss-env.age`:

```bash
SECRET_KEY_BASE=...
POOL_SIZE=5
```

```bash
sudo -u earss bash -lc '
  set -a
  source '"$(# path:)"'/run/agenix/earss-env
  set +a
  # peer DB URL is already in the unit env; export it if running outside systemd:
  export DATABASE_URL="${DATABASE_URL:-ecto://earss@/earss?host=/run/postgresql}"
  /nix/store/…/bin/earss eval "Earss.Release.seed_admin(\"admin\", \"change-me\")"
'
```

Find the binary: `systemctl cat earss` and read `ExecStart=`.

---

## 4. Expose to clients

| Mode | Config |
|------|--------|
| **Tailscale only** | No public firewall; NNW → `http://homeserver:4000/api/greader.php` on tailnet |
| **nginx + ACME** | `services.earss.configureNginx = true;` + `virtualHost = "rss.example.com";` + ACME email |
| **Caddy (separate)** | `reverse_proxy 127.0.0.1:4000` |

Admin UI (`/admin`): keep on VPN or add extra auth at the proxy.

---

## 5. Module options (summary)

| Option | Default | Meaning |
|--------|---------|---------|
| `enable` | — | Turn on service |
| `package` | *required* | Release derivation |
| `secretKeyBaseFile` | `null` | Credential file for `SECRET_KEY_BASE` |
| `environmentFile` | `null` | systemd env file (secrets + overrides) |
| `settings` | `{}` | Non-secret env attrs |
| `port` | `4000` | Listen port |
| `openFirewall` | `false` | Open TCP port |
| `user` / `group` | `earss` | Service identity |
| `dataDir` | `/var/lib/earss` | State home |
| `database.createLocally` | `true` | Manage local PG + citext |
| `database.name` / `user` | `earss` | DB identifiers |
| `database.passwordFile` | `null` | Use TCP + password instead of peer |
| `migrateOnStart` | `true` | `Earss.Release.migrate()` in `preStart` |
| `configureNginx` | `false` | Reverse proxy vhost |
| `virtualHost` | `rss.example.com` | nginx server name |

Full behaviour: [`nix/module.nix`](../nix/module.nix).

---

## 6. Upgrades

```bash
# bump input
nix flake update earss

# if mix.lock / plugins changed, refresh mixDepsHash in earss flake first
sudo nixos-rebuild switch --flake .#homeserver
```

`migrateOnStart = true` applies pending Ecto migrations before the new binary stays up.

Rollback: previous NixOS generation (`nixos-rebuild switch --rollback`) + restore DB if a migration was destructive (prefer additive migrations).

---

## 7. Backups

Still the same as [backup.md](backup.md):

```nix
# example: daily dump
systemd.services.earss-backup = {
  serviceConfig.Type = "oneshot";
  serviceConfig.User = "postgres";
  script = ''
    ${config.services.postgresql.package}/bin/pg_dump -Fc -f /var/backup/earss/earss-$(date -u +%Y%m%d).dump earss
  '';
};
systemd.timers.earss-backup = {
  wantedBy = [ "timers.target" ];
  timerConfig.OnCalendar = "daily";
};
```

Also back up `SECRET_KEY_BASE` (agenix identity + secret file).

---

## 8. Troubleshooting

| Symptom | Check |
|---------|--------|
| Release build hash mismatch | Update `mixDepsHash` in `flake.nix` |
| Deps FOD fails with git | Pin plugins; ensure `cacert`/`git` in build (already in package.nix) |
| App crash: `SECRET_KEY_BASE is missing` | `secretKeyBaseFile` or `environmentFile` not visible to service user |
| App crash: DB connection | `journalctl -u earss -e`; peer auth needs `user == database.user`; citext service green |
| `citext` errors on migrate | `systemctl status earss-postgres-setup` |
| Plugins missing at runtime | They must be in **`sourcePlugins` at build**; rebuild release |

```bash
journalctl -u earss -f
curl -sS http://127.0.0.1:4000/health
```

---

## 9. Without using this flake’s package

You can still use only the module:

```nix
services.earss = {
  enable = true;
  package = pkgs.callPackage /path/to/earss/nix/package.nix {
    inherit (pkgs.beamPackages) fetchMixDeps mixRelease;
    mixDepsHash = "sha256-…";
    sourcePlugins = "";
  };
  environmentFile = config.age.secrets.earss-env.path;
};
```

Or point `package` at any derivation that installs `bin/earss` (manually copied release under `pkgs.runCommand`, etc.).

---

## Related

- [deploy.md](deploy.md) — non-Nix release workflow  
- [backup.md](backup.md) — dump/restore  
- [development.md](development.md) — local Mix  
- [sources.md](sources.md) — plugins  
