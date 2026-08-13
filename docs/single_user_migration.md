# Migration guide: single-user (db-schema-v2) on NixOS

> Applies to existing NixOS deployments (flake + `services.earss`) with
> live data, moving to the `refactor/single-user` branch / `db-schema-v2`.
> Read [single_user.md](single_user.md) first for what changed.

## What changes for you

| Area | Before | After |
|------|--------|--------|
| Database | `users` + per-user rows | **`users` table dropped**; subscriptions/categories/entry_states become single-operator rows |
| Admin login | username + password (DB) | **password only** — `ADMIN_PASSWORD` from the environment |
| NetNewsWire **FreshRSS/GReader** account | per-user password | password = **`ADMIN_PASSWORD`** (username: anything, e.g. `earss`) |
| NetNewsWire **Fever** account | MD5-derived api key | fixed **`FEVER_API_KEY`** from the environment |
| Data kept | — | the **first (lowest-id) user's** subscriptions, categories and entry states are kept; **all other users' rows are deleted** |

Credentials are checked with constant-time comparison in
`Earss.OperatorAuth`; nothing is stored in the database anymore.

## Step 0 — back up the database (mandatory)

The migration is destructive for non-first-user data. On the NixOS host:

```bash
sudo -u postgres pg_dump -Fc -f /var/lib/earss/pre-v2-backup.dump earss
# verify the backup is readable:
sudo -u postgres pg_restore --list /var/lib/earss/pre-v2-backup.dump | head
```

Copy the dump off-host (or into your usual backup rotation) before
continuing. Full restore procedure at the bottom.

## Step 1 — pin the new revision in the host flake

Point the earss input at the migration commit (prefer an explicit commit
pin over the branch for reproducibility):

```nix
inputs.earss = {
  # db-schema-v2 (single-user) — 3a5f451…
  url = "github:ll1zt/earss/3a5f45136f6d3b1c8d9e0f2a4b5c6d7e8f9a0b1c";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

(Substitute the exact commit hash from `git rev-parse db-schema-v2` in
the earss checkout.)

Refresh the lockfile and rebuild the derivation:

```bash
nix flake lock --update-input earss
nix build .#nixosConfigurations.<host>.config.services.earss.package
```

If `mixDepsHash` mismatches (the dep set is unchanged, but hashes can
drift), update it in your `mkEarss` call from the error message.

## Step 2 — configure the new credentials

In your secrets file (`services.earss.environmentFile`, e.g.
`/run/agenix/earss-env`):

```env
# KEEP THE EXISTING VALUE — it signs all tokens. Changing it logs out
# every client and invalidates GReader auth tokens.
SECRET_KEY_BASE=<unchanged>

# New: single operator password (admin UI, JSON API, GReader ClientLogin)
ADMIN_PASSWORD=<a strong password>

# New: fixed Fever key (NetNewsWire Fever accounts; random hex is fine)
FEVER_API_KEY=$(openssl rand -hex 16)
```

No NixOS module changes are required — `ADMIN_PASSWORD` and
`FEVER_API_KEY` are read from the process environment, so
`environmentFile` / agenix / sops-nix all work as before.

## Step 3 — run the migration explicitly (recommended)

`migrateOnStart` runs migrations in the systemd `preStart`, but for a
data-changing migration it is safer to run it manually once and inspect
the result first.

```bash
# stop the service so nothing writes during the migration
sudo systemctl stop earss

# run as the service user so peer auth works
sudo -u earss earss eval 'Earss.Release.migrate()'
```

Expected output ends with `Migrated 20260813000002` (db-schema-v2).

Verify:

```bash
sudo -u postgres psql -d earss -c '\dt'
# users table must be gone; subscriptions / categories / entry_states remain

sudo -u postgres psql -d earss -c \
  'SELECT count(*) AS subs FROM subscriptions;
   SELECT count(*) AS states FROM entry_states;
   SELECT count(*) AS cats FROM categories;'
```

The kept rows are those of the first (lowest-id) user. **If the counts
are not what you expect, restore the backup (see below) before
deploying.**

## Step 4 — deploy and verify

```bash
sudo nixos-rebuild switch --flake .#<host>

sudo systemctl start earss
systemctl status earss --no-pager
curl -sf http://127.0.0.1:4000/health
```

The service logs a warning at boot when `ADMIN_PASSWORD` /
`FEVER_API_KEY` are missing — that is expected until Step 2 lands in the
environment.

## Step 5 — reconfigure clients

| Client account type | Username | Password |
|---------------------|----------|----------|
| NetNewsWire **FreshRSS/GReader** | anything (`earss`) | **`ADMIN_PASSWORD`** |
| NetNewsWire **Fever** | anything | **`FEVER_API_KEY`** |

Because `SECRET_KEY_BASE` is unchanged, existing GReader auth tokens
remain valid; only new logins need the new password. Admin UI:
`/admin`, password only.

## Rollback

### Restore from backup (full, recommended)

```bash
sudo systemctl stop earss
sudo -u postgres pg_restore --clean --if-exists -d earss /var/lib/earss/pre-v2-backup.dump
```

Switch the flake input back to the previous revision, `nixos-rebuild
switch`, start the service. The old admin password works again (it is
stored in the restored `users` table).

### `down` migration (best-effort)

`earss eval 'Earss.Release.rollback(step: 1)'` restores the v1 table
shape, but it **cannot restore deleted users' rows** — it re-attaches
all rows to a single placeholder `operator` user. Use the backup
instead unless you only ever had one user.

## Notes

- The migration is idempotent; re-running `migrate()` is a no-op.
- `earss.env` in the release root is an alternative to
  `environmentFile` for these keys (shell/env precedence unchanged).
- After a successful migration the backup can join your normal rotation;
  keep one pre-v2 snapshot until you have used the new build for a few
  days.
