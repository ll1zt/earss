# Roadmap

This roadmap starts from the frozen milestone **`db-schema-v1`**.

## Done — `db-schema-v1`

- [x] Six-table relational model with indexes and CHECKs
- [x] English-facing design docs for model, lifecycle, scheduler
- [x] Ecto schemas aligned with migrations
- [x] Env-split config (`dev` / `test` / `prod` / `runtime`)
- [x] Schema contract tests
- [x] Minimal user create / authenticate / delete

## Phase 1 — Feeds context (ingest primitives) ✅

**Goal:** create and update feeds/entries without live HTTP yet (or with a thin client behind an interface).

- [x] `Earss.Feeds.create_feed/1`, `get_feed_by_link/1`, `ensure_feed/2`, `update_feed/2`
- [x] `upsert_entry/2` and `upsert_entries/2` with guid normalization (D4)
- [x] `list_entries/2` + context tests (`test/earss/feeds_test.exs`)
- [ ] Optional: store fixture XML/JSON for parser golden tests (Phase 2)

## Phase 2 — Fetch & parse ✅

**Goal:** turn a feed URL into structured entries.

- [x] HTTP client dependency (`req`) with swappable `Earss.Feeds.HTTP`
- [x] Conditional requests via `etag` / `last_modified` (304)
- [x] Body hash → `last_fetched_content_hash` (skip re-ingest when unchanged)
- [x] RSS / Atom / JSON Feed parser (`Earss.Feeds.Parser` + fixtures)
- [x] `Earss.Feeds.Fetcher` / `Feeds.refresh/1` upserts entries and updates feed metadata
- [x] Error classification (`{:http, _}`, `{:parse, _}`); simple 5-strike disable

## Phase 3 — Scheduler runtime ✅

**Goal:** implement [feed_scheduler_guide.md](feed_scheduler_guide.md).

- [x] `Earss.FeedScheduler` pure + Repo helpers
- [x] D1 effective interval including hidden-sub exclusion
- [x] Adaptive success / no-content / error paths (used by `Fetcher`)
- [x] Due-feed query with subscriber existence guard
- [x] GenServer `Earss.FeedPoller` wired into `Application` (disabled in test)
- [x] Manual force refresh remains `Feeds.refresh/1`

## Phase 4 — Reader product surface ✅

**Goal:** complete personalization APIs used by any future client.

- [x] Categories CRUD + `position`
- [x] Subscribe / unsubscribe / hide / custom title / custom interval
- [x] Lifecycle side effects from [data_lifecycle.md](data_lifecycle.md)
- [x] Mark read / unread / star; lazy state creation (D2)
- [x] Unread / starred / per-feed / per-category listing queries
- [x] Context tests in `test/earss/reader_test.exs`

## Phase 5 — Retention jobs ✅

**Goal:** enforce D3 / D6 safely in production-shaped cron.

- [x] Level A state cleanup (`Earss.Retention.purge_expired_states/1`)
- [x] Level B entry reclaim (`purge_reclaimable_entries/1`)
- [x] Zero-subscriber feed purge (`purge_unsubscribed_feeds/1`)
- [x] `run_all/1`, dry_run, batching, logging
- [x] `Earss.RetentionPoller` (daily; disabled in test)
- [x] Subscribe refresh moved **outside** DB transaction

## Phase 6 — HTTP API

**Goal:** expose a stable client interface.

### 6a — api-v0.1 ✅

- [x] **Plug + Bandit** JSON API (no Phoenix)
- [x] Auth: signed Bearer token (`Earss.API.Token`)
- [x] REST: me, categories, subscriptions, entries, read/star, feed refresh
- [x] Conn tests (`test/earss/api_test.exs`)
- [x] [docs/api.md](api.md)

### 6b — api-v1 ✅ (core)

- [x] OPML import/export (`Earss.Reader.OPML` + `/api/opml/*`)
- [x] Batch mark-read (`mark_entries_read` + `POST /api/entries/mark_read`)
- [x] Subscription unread counts (`with_unread_count`)
- [x] Parser robustness (BOM, guid-only link, basic entities, atom link href)
- [x] OpenAPI contract ([docs/openapi.yaml](openapi.yaml) — JSON API)
- [ ] Token revocation table (optional)

## Phase W1 — Fever API (NetNewsWire) ✅ `fever-v0.1`

- [x] `users.fever_api_key` + create/set password helpers
- [x] `POST/GET /fever/?api` (form + query)
- [x] groups, feeds, feeds_groups, items, unread/saved ids, mark item/feed/group
- [x] docs/fever.md + tests
- [x] Web Admin UI (`admin-v0.1`, `/admin`)
- [x] Web Admin source ops (`admin-v0.2`): subscription detail edit, list filters, feeds health/batch refresh, System + retention (admin-only), category rename
- [x] Google Reader / FreshRSS API (`greader-v0.1`, `/api/greader.php`) for NetNewsWire FreshRSS accounts
- [x] NNW compatibility hardening: numeric `feed/<id>`, hex `/item/*` parse, multi-value form `i=`, required contents `updated`, tag folders, ingest-time floor, `ot` watermarks
- [x] GReader subscription/edit (subscribe / unsubscribe / title+folder) + edit-token on mutating routes
- [x] Fever: `feeds_groups` on feeds-only; correct `total_items`; short GReader stream ids
- [x] CSRF for admin forms (`Plug.CSRFProtection` + `_csrf_token` on POST forms)
- [x] OpenAPI for **own** JSON API ([docs/openapi.yaml](openapi.yaml)); Fever / GReader remain protocol docs

## Phase 7 — Hardening

- [x] Rate limits / host politeness (`Earss.Feeds.HostLimiter`, per-host concurrency + min interval + 429/503 cooldown; poller host interleave)
- [x] Content sanitization for HTML bodies (`Earss.Feeds.HTMLSanitize` on entry upsert)
- [x] Backup/restore notes ([docs/backup.md](backup.md))
- [ ] Observability (telemetry events for fetch latency, errors)
- [ ] Sub-user permission model if still required

## Phase S — Source adapters / plugins (design → implement)
Design doc: [sources.md](sources.md). Locked: **R1** (`earss://`) · **C2** (`earss_source` package).

- [x] **S0** — Design doc (`docs/sources.md`), index + architecture pointers
- [x] **S1** — `packages/earss_source` path package (behaviour, types, `adapter_api` = 1)
- [x] **S2** — Registry + native adapter; `Fetcher` dispatches with **no** user-visible change for HTTP feeds
- [x] **S3** — Additive schema (`adapter_id`, `source_kind`, `adapter_cursor`, `adapter_config`, `feed_type=plugin`) + `ensure_feed` / subscribe for `earss://` (stub coverage in tests)
- [x] **S4** — Reference plugin [`earss_source_telegram`](https://github.com/ll1zt/earss_source_telegram) (`earss://telegram/channel/…`); enable via `EARSS_SOURCE_PLUGINS=github:ll1zt/earss_source_telegram@main`
- [x] **S5** — Admin `/admin/sources`: adapter list, route catalog, URL + param subscribe wizard
- [x] **S6** — `Earss.Source.Politeness`, author guide + OPML/`earss://` notes (`docs/sources.md`, `earss_source` README)

## Phase T — Translation (Goal 2)
Design doc: [translate.md](translate.md). Enrichment contract lives in `earss_source` (`Earss.Source.Enricher`, `adapter_api` = 1; translation is its first use, TTS can follow).

- [x] **T1** — Enricher contract (`Earss.Source.Enricher`: `enrich/2` with opaque content + strict ref/type validation, optional `skip?/2` + `split_blocks/1`) in `packages/earss_source`
- [x] **T2** — Reference plugin [`earss_translate_openai`](../earss_translate_openai) (OpenAI-compatible; enable via `EARSS_TRANSLATE_PLUGINS`)
- [x] **T3** — Additive schema: `feeds.translate_to/translate_from/translate_error_count/original_layout`, `subscriptions.translate_to/original_layout`, `entry_translations` `(entry_id, lang)`, `entries.translation_pending_at/translation_retry_count`
- [x] **T4** — `Earss.Enrichment.Registry` + discovery (`EARSS_TRANSLATE_PLUGINS` / `EARSS_TRANSLATE_ADAPTERS` / `earss_translate_*` apps)
- [x] **T5** — `Earss.Enrichment` orchestration (languages, budget, pending publish model, retry + give-up) — domain algorithm (HTML blocks, provider calls, skip heuristics) lives in the plugin
- [x] **T6** — Ingest hook in `Fetcher` (best-effort, error_count only)
- [x] **T7** — Plugin-owned block-preserving extraction/reassembly with placeholder validation (`EarssTranslateOpenai.HTML`)
- [x] **T8** — Protocol view: GReader + Fever serve translations (`?original=1` escape hatch; subscription override appends original)
- [x] **T9** — Control plane: `/admin/translate`, per-feed / per-subscription forms, category batch, `?translate_to` on `/api/entries`
- [x] **T10** — End-to-end integration test (refresh → translate → GReader stream)
- [x] **T11** — Docs (`docs/translate.md`, api.md, roadmap)

## Suggested near-term order

1. Phase 1 (Feeds upsert) — unblocks everything else  
2. Phase 2 (fetch/parse) — first vertical slice with a real URL  
3. Phase 3 (scheduler) — unattended freshness  
4. Phase 4 (Reader APIs) — usable multi-user product core  
5. Phases 5–7 as needed for longevity and clients  
6. **Phase S** when non-RSS sources are required — start S1/S2 without blocking readers  

## Non-goals (explicitly deferred)

- Mobile/desktop official clients
- Full-text search cluster
- Multi-region active-active
- Replacing the schema freeze without a new versioned milestone (`db-schema-v2`, …)
- Built-in multi-site scraper catalog (use plugins or external RSSHub)
- Runtime installation of untrusted plugin code
