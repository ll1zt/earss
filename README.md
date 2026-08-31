# Earss

Self-hosted **RSS / Atom / JSON Feed** reader backend written in Elixir — with optional
**plugin sources** (Telegram, Zhihu, …) and **automatic translation** of articles.

Earss stores feed content once and keeps your reading state separate. You manage
sources in a small **Admin console** and read in **NetNewsWire** (Fever or
FreshRSS/GReader account) — or any client speaking those protocols.

> 📖 **Just want to use it?** Start with the [User Guide](docs/usage.md):
> install → subscribe → connect your reader → daily ops, all in one page.

## What you get

- 📥 **Ingest** RSS / Atom / JSON Feed with conditional requests (etag/304), content-hash
  de-duplication, per-host politeness, adaptive scheduling and a 5-strike circuit breaker
- 🔌 **Plugin sources** via `earss://` URLs (optional Mix deps, no host catalog) — see
  [docs/sources.md](docs/sources.md)
- 🌐 **Translation** of new articles into a target language (OpenAI-compatible plugin),
  hidden-until-ready publishing, per-feed control, batch retry/publish — [docs/translate.md](docs/translate.md)
- 📱 **Client protocols**: Fever (`/fever/`) and FreshRSS / Google Reader
  (`/api/greader.php`), both verified against NetNewsWire, plus a JSON API with an
  OpenAPI contract — [docs/api.md](docs/api.md)
- 🖥️ **Admin console** (`/admin`, kami/parchment theme): subscribe / OPML, health table,
  batch operations, translation control, live metrics, export, retention jobs
- 🎧 **Listen later**: a "🎧 Listen" control in your reader synthesizes articles to
  audio (TTS plugin) and republishes them as an Apple-Podcasts-compatible feed —
  [docs/tts.md](docs/tts.md)
- 📊 **Observability**: in-memory telemetry store with fetch outcomes, latency and a
  failure feed on `/admin/metrics` — no external deps
- 💾 **Backup-friendly**: everything meaningful lives in PostgreSQL — [docs/backup.md](docs/backup.md)

## Quick start (development)

```bash
mix setup                  # deps.get + ecto.create + ecto.migrate
iex -S mix                 # start app (Repo, pollers, HTTP on :4000)
```

Set the operator credentials in `earss.env` (single-operator mode):

```bash
cp earss.env.example earss.env
# ADMIN_PASSWORD=<a strong password>
# FEVER_API_KEY=<random hex for NetNewsWire Fever>
```

Then open:

| What | Where |
|------|-------|
| Admin console | `http://localhost:4000/admin` |
| NetNewsWire (FreshRSS account) | `http://localhost:4000/api/greader.php` — password: `ADMIN_PASSWORD` |
| NetNewsWire (Fever account) | `http://localhost:4000/fever/` — password: `FEVER_API_KEY` |

**Docker Compose**: `cp .env.docker.example .env` → `docker compose up -d --build`
— [docs/docker.md](docs/docker.md). **NixOS**: declarative module —
[docs/nixos.md](docs/nixos.md). **Bare-metal release + systemd**:
[docs/deploy.md](docs/deploy.md).

Default **dev** DB (`config/dev.exs`): database `earss_dev`, user `postgres`,
empty password, host `localhost`.

## Operator environment (`earss.env`)

| When | Consumer | Examples |
|------|----------|----------|
| `mix deps.get` | `mix.exs` | `EARSS_SOURCE_PLUGINS`, `EARSS_TRANSLATE_PLUGINS` |
| app boot (not test) | `config/runtime.exs` | `DATABASE_URL`, `PORT`, `POLLER_*`, `RETENTION_*`, `HTTP_*`, … |

Shell / CI env wins over the file. Production **requires** `DATABASE_URL` +
`SECRET_KEY_BASE`. Admin `/admin/system` shows the merged config (read-only);
`/admin/settings` shows a cheat sheet of the common keys with current values.
Full list: [`earss.env.example`](earss.env.example).

## Optional source plugins

Free-form Mix specs (no host catalog) in `earss.env`:

```bash
EARSS_SOURCE_PLUGINS=github:ll1zt/earss_source_telegram@main
mix deps.get && mix compile
iex -S mix
```

Telegram example: `earss://telegram/channel/journey_of_someone`.
Details: [docs/sources.md](docs/sources.md).

## Runtime

```
Earss.Supervisor
├── Earss.Source.Registry / Earss.Enrichment.Registry   # plugin registries (Earss.Registry)
├── Earss.Enrichment.Limiter                            # provider concurrency gate (Earss.ConcurrencyGate)
├── Earss.Enrichment.TaskSupervisor + PendingWorker
├── Earss.Telemetry.Store    # in-memory metrics (config :telemetry)
├── Earss.Repo
├── Earss.Feeds.HostLimiter  # per-host crawl politeness (config :host_politeness)
├── Earss.FeedPoller         # due-feed fetch batches (config :poller)
├── Earss.RetentionPoller    # daily cleanup (config :retention_poller)
└── Bandit + Earss.API.Router  # HTTP (config :api, default :4000)
```

## Project layout

```
lib/earss/
  application.ex        # boot: registries, plugins, telemetry handler
  registry.ex           # generic plugin registry (source/enrichment/TTS facades)
  plugins.ex            # runtime plugin discovery & registration
  concurrency_gate.ex   # leak-proof provider concurrency gate
  telemetry.ex / telemetry/store.ex
  feeds.ex / feeds/*    # shared feeds, HTTP, parser, fetcher, sanitize, limiter
  feed_scheduler.ex / feed_poller.ex
  reader.ex / reader/*  # categories, subs, states, timeline, OPML
  retention.ex / retention_poller.ex
  fever.ex / greader.ex
  api/*                 # Plug JSON + Fever + GReader mounts
  admin/*               # session Admin UI (controllers / views / helpers)
priv/repo/migrations/
config/
docs/
test/
```

## Contexts

| Context | Responsibility |
|---------|----------------|
| **Earss.Feeds** | Global feeds & entries (shared crawl + storage) |
| **Earss.Reader** | Categories, subscriptions, read/star state for the operator |

## Current status

| Area | Status |
|------|--------|
| Data model & migrations | Frozen (`db-schema-v2`, single-operator) |
| Feed fetch / parse / refresh | Done (Phase 2) |
| Scheduler + poller | Done (Phase 3) |
| Reader subscriptions / states / timeline | Done (Phase 4) |
| Retention jobs | Done (Phase 5) |
| HTTP API (Plug + Bandit) | Done (`api-v0.1` / `api-v1` core, OpenAPI) |
| Fever API (NetNewsWire) | Done (`fever-v0.1`) |
| FreshRSS / Google Reader API | Done (`greader-v0.1`, NNW-verified) |
| Web Admin UI | Done (`admin-v0.3`, kami theme, batch ops, pagination) |
| Source plugins | S1–S6 core + optional Telegram / Zhihu / … |
| Translation (Goal 2) | Done (`T1–T11`, plugin: `earss_translate_openai`) |
| Listen-later / TTS (Goal 3) | Done (signed links, synthesis worker, podcast feed) |
| Observability | Done (telemetry events + `/admin/metrics`) |

## Requirements

- Elixir `~> 1.18`
- PostgreSQL with permission to create the `citext` extension
- Mix deps: `ecto_sql`, `postgrex`, `argon2_elixir`, `req`, `jason`, `sweet_xml`, `bandit`, `plug`

## Production (release)

```bash
# Optional plugins are compile-time deps:
# export EARSS_SOURCE_PLUGINS='github:ll1zt/earss_source_telegram@main'
MIX_ENV=prod mix deps.get --only prod
MIX_ENV=prod mix release
```

On the server (with `DATABASE_URL` + `SECRET_KEY_BASE`):

```bash
_build/prod/rel/earss/bin/earss eval "Earss.Release.migrate()"
_build/prod/rel/earss/bin/earss start
```

## Documentation

**Use it**

| Doc | Description |
|-----|-------------|
| [User guide](docs/usage.md) | End-to-end operator guide (start here) |
| [Web Admin](docs/admin.md) | Every page of the console, batch ops, UX conventions |
| [Fever API](docs/fever.md) | NetNewsWire → Fever account |
| [GReader / FreshRSS API](docs/greader.md) | NetNewsWire → FreshRSS account |
| [HTTP API](docs/api.md) | JSON API + OpenAPI contract |
| [Translation](docs/translate.md) | Enabling, semantics, ops |
| [Listen later / TTS](docs/tts.md) | Synthesizing articles, podcast feed, ops |
| [MCP server](docs/mcp.md) | Agent-facing MCP endpoint: browse, ingest, translate, TTS |
| [PGroonga 全文搜索](docs/pgroonga.md) | 多语言搜索启用指南（NixOS / 手动 / Docker） |
| [Source adapters & plugins](docs/sources.md) | `earss://` plugins, authoring |

**Run it**

| Doc | Description |
|-----|-------------|
| [Deploy](docs/deploy.md) | Mix release, systemd |
| [Docker](docs/docker.md) | Compose quick start |
| [NixOS](docs/nixos.md) | Declarative homeserver module |
| [Backup](docs/backup.md) | pg_dump / restore |

**Hack it**

| Doc | Description |
|-----|-------------|
| [Development](docs/development.md) | Setup, config, testing, conventions |
| [Architecture](docs/architecture.md) | Goals, contexts, design boundaries |
| [Data model](docs/data_model.md) | Tables, constraints, decisions D1–D7 |
| [Data lifecycle](docs/data_lifecycle.md) | Side effects for subscribe, fetch, cleanup |
| [Feed scheduler](docs/feed_scheduler_guide.md) | Adaptive refresh design |
| [Roadmap](docs/roadmap.md) | Phased plan |

## License

See [LICENSE](LICENSE).
