# Architecture

## What Earss is

Earss is a **self-hosted feed reader backend**. It is not a full end-user reading UI. The shape is:

1. Ingest RSS / Atom / JSON Feed sources on a schedule
2. Store article content **once per source**
3. Expose per-user subscriptions, categories, and read/star state
4. Serve client APIs (own JSON API, Fever, FreshRSS/GReader) and a small Admin console

The project is an OTP application (`Earss.Application`) with **Plug + Bandit** HTTP (no Phoenix).

## Core idea

```
┌─────────────────────────────────────────────────────────┐
│  Shared content                                          │
│  feeds ──< entries                                       │
└───────────────────────────┬─────────────────────────────┘
                            │
┌───────────────────────────▼─────────────────────────────┐
│  Per-user graph                                          │
│  users ──< subscriptions >── feeds                       │
│       └──< categories                                    │
│       └──< entry_states >── entries                      │
└─────────────────────────────────────────────────────────┘
```

- **One crawl, many readers.** If N users subscribe to the same URL, there is still one `feeds` row and one set of `entries`.
- **State is not content.** Read/unread and stars live in `entry_states`, not on `entries`.
- **Categories are optional.** Subscriptions may have `category_id = NULL`. A virtual **“all”** view is application-level, not a stored category.

## Context boundaries

### `Earss.Feeds`

Owns global source metadata and article bodies.

- Upsert feeds by canonical `link`
- Upsert entries by `(feed_id, guid)`
- Fetch scheduling fields on `feeds` (implemented in a later phase)
- Must **not** encode per-user preferences

### `Earss.Reader`

Owns identity and personalization. `Earss.Reader` is a **facade**; logic lives in focused modules (`Users`, `Categories`, `Subscriptions`, `EntryStates`, `Timeline`, `OPMLImport`). Fever-specific list queries live in `Earss.Fever.Queries`.

- Users (`admin` / `sub_user`), password hashing (Argon2)
- Categories, subscriptions, entry states
- On unsubscribe: delete that user’s states for the feed’s entries; update zero-subscriber bookkeeping on the feed

### `Earss.Translate`

Goal 2 translation orchestration (docs/translate.md): picks a registered
`Earss.Source.Translator` plugin, translates new entries at ingest (best-effort,
budgeted) or via admin backfill, stores copies in `entry_translations`
(`(entry_id, lang)`, original rows untouched). `Earss.API.Translation` attaches
the stored translations to protocol rows (GReader/Fever/JSON `?translate_to`)
with a per-row target language: subscription override → feed setting.

Cross-context rules are documented in [data_lifecycle.md](data_lifecycle.md). Prefer explicit function calls over DB triggers.

### Protocol adapters

- **`Earss.GReader`**: FreshRSS / Google Reader JSON; facade over `Auth`, `Ids`, `Streams`, `Items`, `Subscriptions`, `Format`.
- **`Earss.Fever`**: Fever protocol mapping; uses Reader + `Fever.Queries`.

### Admin UI

`Earss.Admin.Router` only dispatches. Page actions are `Earss.Admin.Controllers.*`; HTML is `Earss.Admin.Views.*` plus shared `HTML` / `Helpers`.

### Source adapters

Native RSS/Atom/JSON Feed remains the default (`Earss.Source.Native`). Optional **plugins** implement `Earss.Source.Adapter` from **`earss_source`** (`packages/earss_source`) and register on `Earss.Source.Registry` under `earss://<adapter_id>/…` (**R1** + **C2**). `Feeds.Fetcher` dispatches by adapter. See [sources.md](sources.md).

Reference external plugin: [`earss_source_telegram`](https://github.com/ll1zt/earss_source_telegram) (opt-in via `EARSS_SOURCE_PLUGINS=github:ll1zt/earss_source_telegram@main` in `earss.env` / deploy env).

## Runtime (today)

```
Earss.Supervisor
  ├── Earss.Source.Registry
  ├── Earss.Repo
  ├── Earss.Feeds.HostLimiter     # per-host crawl politeness (config :host_politeness)
  ├── Earss.FeedPoller            # due-feed fetch batches (config :poller)
  ├── Earss.RetentionPoller       # daily cleanup (config :retention_poller)
  └── Bandit + Earss.API.Router   # HTTP (config :api, default :4000)
```

HTTP mounts (same Bandit listener):

| Path | Module | Role |
|------|--------|------|
| `/health` | `Earss.API.Router` | liveness |
| `/admin` | `Earss.Admin.Router` | source management UI |
| `/api/*` | `Earss.API.AuthenticatedRouter` | Bearer JSON API |
| `/fever` | `Earss.API.Fever` | Fever protocol |
| `/api/greader.php` | `Earss.API.GReader` | FreshRSS / Google Reader (NNW) |

## Configuration surface

| Key | Role |
|-----|------|
| `Earss.Repo` | Database connection |
| `:earss, :refresh` | Default min / max / default fetch intervals (minutes) |
| `:earss, :retention` | Cleanup windows (days) |
| `:earss, :poller` | Feed poller enable / interval / batch / concurrency |
| `:earss, :host_politeness` | Per-host concurrent + min interval + 429 cooldown |
| `:earss, :retention_poller` | Retention job enable / interval |
| `:earss, :api` | HTTP enable / port / `secret_key_base` / token TTL |

See [data_model.md](data_model.md) for interval/retention defaults (decision **D7**).

## Non-goals (for now)

- Full OPML UI product
- Multi-tenant SaaS billing / orgs
- Nested category trees
- Podcast enclosure pipeline
- Fine-grained RBAC beyond `admin` vs `sub_user` labels

## Related docs

- Schema contract: [data_model.md](data_model.md)
- Event side effects: [data_lifecycle.md](data_lifecycle.md)
- Scheduling algorithm notes: [feed_scheduler_guide.md](feed_scheduler_guide.md)
- Implementation phases: [roadmap.md](roadmap.md)
