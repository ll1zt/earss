# Backup and restore

> 📖 What to back up and when: [User guide → Daily ops](usage.md).

Earss stores all application state in **PostgreSQL**. There is no separate
session or token store. A correct backup is primarily a database dump plus
the operator secrets you use to run the app.

## What to back up

| Asset | Why |
|-------|-----|
| **PostgreSQL database** | Users, password hashes, Fever keys, categories, subscriptions, feeds, entries, entry_states, migrations |
| **`SECRET_KEY_BASE`** (env / `earss.env`) | Signs API Bearer tokens and Admin session cookies. Changing it invalidates all existing tokens/sessions |
| **Operator env** (`earss.env`, deploy secrets) | `DATABASE_URL`, ports, poller/retention, `EARSS_SOURCE_PLUGINS`, … |
| **Plugin sources (optional)** | If you pin private plugins via `path:` or private git, keep those repos/tags available for restore |

Not required for data restore:

- `_build/`, `deps/` — reinstall with Mix
- Bandit process state — ephemeral
- Client apps (NetNewsWire) — re-login after restore if `SECRET_KEY_BASE` changed

### Partial export (not a full backup)

- **OPML** (`GET /api/opml/export` or Admin): subscription list only (and `earss://` plugin URLs). **No** articles, read/star state, or passwords.
- Re-subscribing after OPML import re-crawls feeds; history is not restored.

## Prerequisites

- PostgreSQL client tools: `pg_dump`, `pg_restore` and/or `psql`
- Same **major** Earss schema family when possible (see [Migrations](#migrations-and-app-version) below)
- Ability to stop or quiesce writers for a consistent dump (recommended)

Connection examples:

```bash
# Production-style URL (from env)
export DATABASE_URL='ecto://USER:PASS@HOST:5432/earss'

# Dev defaults (config/dev.exs): database earss_dev, user postgres, empty password
export PGHOST=localhost
export PGUSER=postgres
export PGDATABASE=earss_dev
```

`DATABASE_URL` uses the `ecto://` scheme. For `pg_dump`/`psql`, convert to a
libpq URL or discrete flags:

```bash
# ecto://user:pass@host:5432/db  →  postgresql://user:pass@host:5432/db
export PG_URL="${DATABASE_URL/ecto:/postgresql:}"
```

## Backup

### 1. Logical dump (recommended)

**Custom format** (flexible restore, parallel-friendly):

```bash
# Stop or pause the Earss app first if you need a quiet snapshot
# (optional but cleaner under heavy poller load)

pg_dump --format=custom --file="earss-$(date -u +%Y%m%dT%H%M%SZ).dump" "$PG_URL"
# or without URL:
# pg_dump -Fc -f earss.dump -h localhost -U postgres earss_dev
```

**Plain SQL** (easy to inspect, larger):

```bash
pg_dump --format=plain --file="earss-$(date -u +%Y%m%dT%H%M%SZ).sql" "$PG_URL"
```

Include roles only if you manage them outside the dump (usually **omit**
`--create` / global roles and recreate the empty database on restore).

### 2. Secrets and config

```bash
# Keep offline / in a secret manager — never commit
cp earss.env "earss.env.backup-$(date -u +%Y%m%d)"
# Also record SECRET_KEY_BASE if it lives only in the process environment
```

### 3. Verify

```bash
# Custom format
pg_restore --list earss-….dump | head

# Plain SQL — non-empty and contains schema/data
wc -l earss-….sql
grep -E 'CREATE TABLE|COPY public\.(users|feeds|entries)' earss-….sql | head
```

Store dumps encrypted at rest and off-box (object storage, another host).
Retention policy is operational: daily dumps + weekly longer retention is a
common starting point.

## Restore

### 1. Prepare an empty database

```bash
# Example: recreate empty DB (destroys existing data on that DB name)
dropdb --if-exists earss_restore   # or your target name
createdb earss_restore

# citext is required by Earss migrations / schema
psql -d earss_restore -c 'CREATE EXTENSION IF NOT EXISTS citext;'
```

If you restore into a name that already has tables, prefer drop/recreate or
restore into a fresh database, then cut over `DATABASE_URL`.

### 2. Load the dump

**Custom format:**

```bash
pg_restore --no-owner --no-acl --dbname="$PG_URL" earss-….dump
# Ignore harmless errors about extensions already existing if you pre-created citext
```

**Plain SQL:**

```bash
psql "$PG_URL" -v ON_ERROR_STOP=1 -f earss-….sql
```

### 3. Application version and migrations

1. Check out the **same Earss git revision** you used in production (or newer
   within the same schema line — see below).
2. Install deps and point `DATABASE_URL` at the restored database.
3. Run:

```bash
mix ecto.migrate
```

- Restoring a dump from a **running** instance usually already includes
  applied migrations (`schema_migrations` table). `mix ecto.migrate` then
  becomes a no-op or applies only newer migrations from a newer app release.
- Restoring only schema-less data is **not** supported; always dump full DB.

If you upgrade Earss **after** restore, migrate forward:

```bash
git checkout <newer-tag>
mix deps.get
mix ecto.migrate
```

Never run an **older** app binary against a DB that has **newer** migrations
without a deliberate downgrade plan (not provided).

### 4. Restart and smoke-check

```bash
# Restore SECRET_KEY_BASE and DATABASE_URL from backup
iex -S mix
# or your release / systemd unit
```

Checks:

```bash
curl -sS http://localhost:4000/health
# => {"status":"ok"}

# Login (Admin or API)
# - Existing Admin sessions may be invalid if SECRET_KEY_BASE changed
# - API tokens issued before a key change are invalid
# - Fever / GReader passwords (user secrets in DB) still work if the DB restored cleanly
```

Optional IEx:

```elixir
Earss.Repo.aggregate(Earss.Reader.User, :count)
Earss.Repo.aggregate(Earss.Feeds.Feed, :count)
Earss.Repo.aggregate(Earss.Feeds.Entry, :count)
```

## Migrations and app version

| Situation | Action |
|-----------|--------|
| Same Earss version as backup | Restore dump → start app → `mix ecto.migrate` (usually idle) |
| Newer Earss than backup | Restore dump → deploy new code → `mix ecto.migrate` |
| Older Earss than DB | Unsupported without reverse migrations |

Schema source of truth: `priv/repo/migrations/` and [data_model.md](data_model.md).

## Plugin sources after restore

If subscriptions use `earss://…` links:

1. Re-enable the same plugins (`EARSS_SOURCE_PLUGINS=…`) **before** or when
   starting the host.
2. `mix deps.get && mix compile` so adapters are on the load path.
3. Without the plugin, existing feed rows remain, but refresh/resolve will fail
   until the adapter is registered again.

OPML with `type="earss"` / `xmlUrl="earss://…"` has the same requirement on
import; full DB restore is preferable to OPML for disaster recovery.

## Minimal checklist

**Backup**

- [ ] `pg_dump` (custom or plain) of the Earss database  
- [ ] Copy of `SECRET_KEY_BASE` and `DATABASE_URL` / `earss.env`  
- [ ] Note Earss git tag/commit and enabled plugins  
- [ ] Verify dump list / spot-check tables  

**Restore**

- [ ] Create empty DB + `citext`  
- [ ] `pg_restore` / `psql -f`  
- [ ] Deploy matching (or newer) Earss + env  
- [ ] `mix ecto.migrate`  
- [ ] Start app; `/health`; login; spot-check feed/entry counts  

## Related

- [Development](development.md) — setup, `earss.env`  
- [Data model](data_model.md) — tables  
- [Data lifecycle](data_lifecycle.md) — retention (affects how much history a dump still holds)  
- Operator template: [`earss.env.example`](../earss.env.example)  

## Related docs

- [TTS / listen-later](tts.md) — synthesis pipeline, podcast feed, ops

> Note: TTS audio files under `EARSS_TTS_AUDIO_DIR` live on disk, outside
> PostgreSQL — `pg_dump` does not cover them. Copy the directory alongside
> the dump if synthesized audio matters to you.
