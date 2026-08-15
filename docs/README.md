# Earss documentation

All project docs are written in **English**.

**Start here**: the [User guide](usage.md) walks through install → subscribe →
connect your reader → daily ops. The root [README](../README.md) has the
product overview and quick start.

## Use it

| Document | Description |
|----------|-------------|
| [User guide](usage.md) | End-to-end operator guide (install, subscribe, NNW, ops, troubleshooting) |
| [Web Admin](admin.md) | Every console page, batch operations, UX conventions |
| [Fever API](fever.md) | NetNewsWire-compatible Fever endpoint |
| [GReader / FreshRSS](greader.md) | Google Reader API for NNW FreshRSS (ids, hex, multi-`i=`) |
| [HTTP API](api.md) | Plug + Bandit JSON API (`api-v0.1` / `api-v1`) |
| [OpenAPI](openapi.yaml) | Machine-readable JSON API contract (OpenAPI 3.1) |
| [Translation](translate.md) | Goal 2: enabling, semantics, operations |
| [Source adapters & plugins](sources.md) | `earss://` plugins, `earss_source` (R1+C2) |

## Run it

| Document | Description |
|----------|-------------|
| [Security](security.md) | Threat model + public-exposure checklist (read before Funnel) |
| [Deploy](deploy.md) | Mix release, env, systemd |
| [Docker / Compose](docker.md) | `Dockerfile` + `docker-compose.yml` (Postgres + release) |
| [NixOS](nixos.md) | Declarative flake package + `services.earss` module |
| [Backup & restore](backup.md) | PostgreSQL dump/restore, secrets, plugins, migrations |

## Hack it

| Document | Description |
|----------|-------------|
| [Architecture](architecture.md) | System goals, contexts, runtime shape |
| [Data model](data_model.md) | Tables, indexes, constraints, decisions D1–D7 |
| [Data lifecycle](data_lifecycle.md) | Side effects for users, subs, fetch, cleanup |
| [Feed scheduler guide](feed_scheduler_guide.md) | Adaptive refresh design and poller behavior |
| [Development](development.md) | Setup, config, tests, conventions |
| [Single-user](single_user.md) | Implemented `db-schema-v2` single-operator conversion |
| [Single-user migration](single_user_migration.md) | NixOS deployment guide: migrating live data to db-schema-v2 |
| [Roadmap](roadmap.md) | Phased work |
