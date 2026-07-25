# Earss

Self-hosted **RSS / Atom / JSON Feed** reader backend written in Elixir.

Earss stores feed content once and keeps per-user reading state separate—similar in spirit to Miniflux-style multi-user readers. It exposes a small Admin UI plus client protocols for **NetNewsWire** (Fever and FreshRSS / Google Reader).

## Current status

| Area | Status |
|------|--------|
| Data model & migrations | Frozen (`db-schema-v1`) |
| Ecto schemas & DB contract tests | Done |
| User create / auth / delete | Minimal |
| Feeds create / entry upsert | Done (Phase 1) |
| Feed fetch / parse / refresh | Done (Phase 2) |
| Scheduler + poller | Done (Phase 3) |
| Reader subscriptions / states / timeline | Done (Phase 4) |
| Retention jobs | Done (Phase 5) |
| HTTP API (Plug + Bandit) | Done (`api-v0.1` / `api-v1` core) |
| Fever API (NetNewsWire) | Done (`fever-v0.1`) |
| FreshRSS / Google Reader API | Done (`greader-v0.1`, NNW-verified) |
| Web Admin UI | Done (`admin-v0.2`, `/admin`) |

## Requirements

- Elixir `~> 1.18`
- PostgreSQL with permission to create the `citext` extension
- Mix deps: `ecto_sql`, `postgrex`, `argon2_elixir`, `req`, `jason`, `sweet_xml`, `bandit`, `plug`

## Quick start

```bash
mix setup                 # deps.get + ecto.create + ecto.migrate
mix test                  # prepares test DB, runs suite
iex -S mix                # start app (Repo, pollers, HTTP on :4000)
```

Create the first user:

```elixir
{:ok, _} = Earss.Reader.create_user("admin", "secret")
```

Then open:

- Admin: `http://localhost:4000/admin`
- Fever (NNW): `http://localhost:4000/fever/`
- FreshRSS / GReader (NNW): `http://localhost:4000/api/greader.php`

Default **dev** DB (`config/dev.exs`):

- database: `earss_dev`
- username: `postgres`
- password: _(empty)_
- hostname: `localhost`

Override locally as needed. Production expects `DATABASE_URL` (see `config/runtime.exs`).

## Runtime

```
Earss.Supervisor
├── Earss.Repo
├── Earss.FeedPoller          # optional, config :poller
├── Earss.RetentionPoller     # optional, config :retention_poller
└── Bandit + Earss.API.Router # optional, config :api (default :4000)
```

## Project layout

```
lib/earss/
  application.ex
  repo.ex
  feeds.ex / feeds/*          # shared feeds, HTTP, parser, fetcher
  feed_scheduler.ex / feed_poller.ex
  reader.ex / reader/*        # users, categories, subs, states, OPML
  retention.ex / retention_poller.ex
  fever.ex / greader.ex
  api/*                       # Plug JSON + Fever + GReader mounts
  admin/*                     # session Admin UI
priv/repo/migrations/
config/
docs/
test/
```

## Contexts

| Context | Responsibility |
|---------|----------------|
| **Earss.Feeds** | Global feeds & entries (shared crawl + storage) |
| **Earss.Reader** | Users, categories, subscriptions, read/star state |

## Documentation

| Doc | Description |
|-----|-------------|
| [Architecture](docs/architecture.md) | Goals, contexts, design boundaries |
| [Data model](docs/data_model.md) | Tables, constraints, frozen decisions D1–D7 |
| [Data lifecycle](docs/data_lifecycle.md) | Side effects for subscribe, fetch, cleanup |
| [Feed scheduler](docs/feed_scheduler_guide.md) | Adaptive refresh design |
| [Development](docs/development.md) | Setup, config, testing, conventions |
| [HTTP API](docs/api.md) | Plug + Bandit JSON endpoints |
| [Fever API](docs/fever.md) | NetNewsWire / Fever clients |
| [GReader / FreshRSS API](docs/greader.md) | NetNewsWire FreshRSS account type |
| [Web Admin](docs/admin.md) | Browser management console |
| [Roadmap](docs/roadmap.md) | Phased plan after db-schema-v1 |

## License

See [LICENSE](LICENSE).
