# Earss documentation

All project docs are written in **English**.

| Document | Description |
|----------|-------------|
| [Architecture](architecture.md) | System goals, contexts, runtime shape |
| [Data model](data_model.md) | Tables, indexes, constraints, decisions D1–D7 |
| [Data lifecycle](data_lifecycle.md) | Side effects for users, subs, fetch, cleanup |
| [Feed scheduler guide](feed_scheduler_guide.md) | Adaptive refresh design and poller behavior |
| [Development](development.md) | Setup, config, tests, conventions |
| [Deploy](deploy.md) | Mix release, env, systemd |
| [Docker / Compose](docker.md) | `Dockerfile` + `docker-compose.yml` (Postgres + release) |
| [NixOS](nixos.md) | Declarative flake package + `services.earss` module |
| [Backup & restore](backup.md) | PostgreSQL dump/restore, secrets, plugins, migrations |
| [HTTP API](api.md) | Plug + Bandit JSON API (`api-v0.1` / `api-v1`) |
| [OpenAPI](openapi.yaml) | Machine-readable JSON API contract (OpenAPI 3.1) |
| [Fever API](fever.md) | NetNewsWire-compatible Fever endpoint |
| [GReader / FreshRSS](greader.md) | Google Reader API for NNW FreshRSS (ids, hex, multi-`i=`) |
| [Web Admin](admin.md) | Session-based management UI |
| [Source adapters & plugins](sources.md) | `earss://` plugins, `earss_source` (R1+C2), S1–S4 + Telegram smoke |
| [Roadmap](roadmap.md) | Phased work after `db-schema-v1` |

Start at the root [README](../README.md) for a short product overview.
