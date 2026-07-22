# Roadmap

This roadmap starts from the frozen milestone **`db-schema-v1`**.

## Done — `db-schema-v1`

- [x] Six-table relational model with indexes and CHECKs
- [x] English-facing design docs for model, lifecycle, scheduler
- [x] Ecto schemas aligned with migrations
- [x] Env-split config (`dev` / `test` / `prod` / `runtime`)
- [x] Schema contract tests
- [x] Minimal user create / authenticate / delete

## Phase 1 — Feeds context (ingest primitives)

**Goal:** create and update feeds/entries without live HTTP yet (or with a thin client behind an interface).

- [ ] `Earss.Feeds.create_feed/1`, `get_by_link/1`
- [ ] `upsert_entry/1` and batch upsert with guid normalization (D4)
- [ ] Unit/integration tests for upsert and uniqueness
- [ ] Optional: store fixture XML/JSON for parser golden tests

## Phase 2 — Fetch & parse

**Goal:** turn a feed URL into structured entries.

- [ ] HTTP client dependency (e.g. Req)
- [ ] Conditional requests via `etag` / `last_modified`
- [ ] Body hash → `last_fetched_content_hash`
- [ ] RSS / Atom / JSON Feed parser (library or small internal layer)
- [ ] Map parser output → entry attrs; set `feed_type`
- [ ] Error classification (network, HTTP 4xx/5xx, parse failure)

## Phase 3 — Scheduler runtime

**Goal:** implement [feed_scheduler_guide.md](feed_scheduler_guide.md).

- [ ] `Earss.FeedScheduler` (or equivalent) pure + Repo functions
- [ ] D1 effective interval including hidden-sub exclusion
- [ ] Adaptive success / no-content / error paths
- [ ] Due-feed query with subscriber existence guard
- [ ] Wire Oban cron **or** GenServer poller into `Application`
- [ ] Manual “force refresh” entry point for later API use

## Phase 4 — Reader product surface

**Goal:** complete personalization APIs used by any future client.

- [ ] Categories CRUD + `position`
- [ ] Subscribe / unsubscribe / hide / custom title / custom interval
- [ ] Lifecycle side effects from [data_lifecycle.md](data_lifecycle.md)
- [ ] Mark read / unread / star; lazy state creation (D2)
- [ ] Unread / starred / per-feed / per-category listing queries
- [ ] Expand tests beyond schema contracts

## Phase 5 — Retention jobs

**Goal:** enforce D3 / D6 safely in production-shaped cron.

- [ ] Level A state cleanup
- [ ] Level B entry reclaim
- [ ] Zero-subscriber feed purge
- [ ] Metrics/logging for deleted counts

## Phase 6 — HTTP API

**Goal:** expose a stable client interface.

- [ ] Phoenix or Plug + JSON
- [ ] Auth sessions or tokens
- [ ] REST (or RPC-style) resources for feeds, entries, states
- [ ] OPML import/export (optional but high value)
- [ ] OpenAPI or similar contract doc

## Phase 7 — Hardening

- [ ] Rate limits / host politeness (per-domain crawl caps)
- [ ] Content sanitization for HTML bodies
- [ ] Backup/restore notes
- [ ] Observability (telemetry events for fetch latency, errors)
- [ ] Sub-user permission model if still required

## Suggested near-term order

1. Phase 1 (Feeds upsert) — unblocks everything else  
2. Phase 2 (fetch/parse) — first vertical slice with a real URL  
3. Phase 3 (scheduler) — unattended freshness  
4. Phase 4 (Reader APIs) — usable multi-user product core  
5. Phases 5–7 as needed for longevity and clients  

## Non-goals (explicitly deferred)

- Mobile/desktop official clients
- Full-text search cluster
- Multi-region active-active
- Replacing the schema freeze without a new versioned milestone (`db-schema-v2`, …)
