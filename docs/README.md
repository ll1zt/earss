# Earss documentation

All project docs are written in **English**.

| Document | Description |
|----------|-------------|
| [Architecture](architecture.md) | System goals, contexts, runtime shape |
| [Data model](data_model.md) | Tables, indexes, constraints, decisions D1–D7 |
| [Data lifecycle](data_lifecycle.md) | Side effects for users, subs, fetch, cleanup |
| [Feed scheduler guide](feed_scheduler_guide.md) | Adaptive refresh design and poller behavior |
| [Development](development.md) | Setup, config, tests, conventions |
| [HTTP API](api.md) | Plug + Bandit JSON API (`api-v0.1` / `api-v1`) |
| [Fever API](fever.md) | NetNewsWire-compatible Fever endpoint |
| [GReader / FreshRSS](greader.md) | Google Reader API for NNW FreshRSS (ids, hex, multi-`i=`) |
| [Web Admin](admin.md) | Session-based management UI |
| [Source adapters & plugins](sources.md) | Design: `earss://` sources, `earss_source` contract (R1+C2) |
| [Roadmap](roadmap.md) | Phased work after `db-schema-v1` |

Start at the root [README](../README.md) for a short product overview.
