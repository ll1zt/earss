# Data model (`db-schema-v1`)

This document is the **source of truth** for the database stage. Field names, defaults, and constraints must match the migrations and Ecto schemas.

Milestone tag: **`db-schema-v1`**.

## Design principles

1. Content is global (`feeds` / `entries`); preferences and reading state are per-user.
2. Schema serves real queries: scheduling, unread lists, stars, cleanup jobs.
3. URLs and long text use PostgreSQL `text`; timestamps are `utc_datetime`.
4. Do not invent extension tables early (enclosures, tokens, ACL tables, etc.).

## Frozen decisions (D1–D7)

| ID | Decision |
|----|----------|
| **D1** | **Refresh aggregation:** take the minimum of eligible `subscription.custom_refresh_interval` values (non-hidden subscriptions only) together with the feed’s scheduling baseline, then **clamp** to `[min_refresh_interval, max_refresh_interval]`. One global crawl per feed. |
| **D2** | **Lazy `entry_states`:** insert/upsert only when the user marks read/star (etc.). **Unread** means “no row” **or** `is_read = false`. |
| **D3** | **Zero subscribers:** stop scheduling; set `last_unsubscribed_at`; after `retention.unsubscribed_feed_days` (default **30**) the feed may be deleted. |
| **D4** | **Same `(feed_id, guid)`:** allow updating mutable content fields; use `content_hash` to detect changes; **do not** reset user states. |
| **D5** | Types: `text` for URLs/titles/bodies; short strings + CHECKs for enums; `timestamps(type: :utc_datetime)`. |
| **D6** | **Cleanup:** Level A — expired read, unstarred states (default **90** days). Level B — reclaimable entries (default **180** days, extra predicates). **Never** delete an entry only because it has no state while still inside the retention window. |
| **D7** | Default interval **30** minutes, min **15**, max **10080** (7 days). |

## Entity relationship

```
users
  ├── categories
  ├── subscriptions ── feeds ── entries
  │         │                      │
  │         └── category (optional)│
  └── entry_states ────────────────┘
```

## Table: `users`

| Column | Type | Notes |
|--------|------|--------|
| `id` | bigserial | PK |
| `username` | citext | Unique, case-insensitive |
| `password_hash` | text | Argon2 (or compatible) hash |
| `user_type` | string | `admin` \| `sub_user` |
| `is_active` | boolean | Default `true` |
| `inserted_at` / `updated_at` | utc_datetime | |

- Unique: `username`
- Check: `user_type IN ('admin', 'sub_user')`
- On delete user → cascade `categories`, `subscriptions`, `entry_states`

## Table: `feeds`

| Column | Type | Default | Notes |
|--------|------|---------|--------|
| `link` | text | | Feed URL, unique |
| `feed_type` | string | `rss` | `rss` \| `atom` \| `json` |
| `site_url` | text | | Site home page |
| `title` / `description` | text | | |
| `last_fetched_at` / `next_fetch_at` | utc_datetime | | Scheduler cursor |
| `refresh_interval` | int | 30 | Current interval (minutes) |
| `min_refresh_interval` | int | 15 | |
| `max_refresh_interval` | int | 10080 | |
| `unchanged_fetch_count` | int | 0 | Consecutive fetches with no new content |
| `error_count` | int | 0 | Consecutive failures |
| `last_error` | text | | |
| `etag` / `last_modified` | text | | HTTP conditional request |
| `last_fetched_content_hash` | text | | Body hash |
| `is_active` | boolean | true | Circuit-breaker / manual disable |
| `last_unsubscribed_at` | utc_datetime | null | Zero-subscriber clock |
| `last_new_entry_at` | utc_datetime | null | Last time new entries appeared |
| timestamps | utc_datetime | | |

**Indexes**

- `unique(link)`
- `(is_active, next_fetch_at)` — primary scheduler index
- partial `(last_unsubscribed_at) WHERE last_unsubscribed_at IS NOT NULL`

**Checks**

- Intervals `> 0` and `max_refresh_interval >= min_refresh_interval`
- `feed_type` enum
- Counts `>= 0`

Scheduler queries (implementation phase) must also require that at least one subscription still exists.

## Table: `entries`

| Column | Type | Notes |
|--------|------|--------|
| `feed_id` | FK → `feeds` | `ON DELETE CASCADE` |
| `link` / `guid` | text | Required; app may fall back `guid = link` |
| `title` / `author` / `summary` / `content` | text | |
| `published_at` | utc_datetime | |
| `content_hash` | text | Helps detect updates for same guid |
| timestamps | utc_datetime | |

- Unique: `(feed_id, guid)`
- Indexes: `(feed_id, published_at)`, `(published_at)`, `(inserted_at)`

## Table: `categories`

| Column | Type | Notes |
|--------|------|--------|
| `user_id` | FK → `users` | `ON DELETE CASCADE` |
| `name` | text | Unique per user |
| `position` | int | Default `0`, display order |
| timestamps | utc_datetime | |

The virtual folder **“all”** is not stored.

## Table: `subscriptions`

| Column | Type | Notes |
|--------|------|--------|
| `user_id` | FK → `users` | `ON DELETE CASCADE` |
| `feed_id` | FK → `feeds` | `ON DELETE CASCADE` |
| `category_id` | FK → `categories` | Nullable; `ON DELETE SET NULL` |
| `custom_title` | text | Display override |
| `custom_refresh_interval` | int \| null | Minutes; `null` = follow feed |
| `is_hidden` | boolean | Default `false` |
| timestamps | utc_datetime | |

- Unique: `(user_id, feed_id)`
- Check: `custom_refresh_interval IS NULL OR custom_refresh_interval > 0`

## Table: `entry_states`

| Column | Type | Notes |
|--------|------|--------|
| `user_id` | FK → `users` | `ON DELETE CASCADE` |
| `entry_id` | FK → `entries` | `ON DELETE CASCADE` |
| `is_read` | boolean | Default `false` |
| `is_star` | boolean | Default `false` |
| `read_at` | utc_datetime | First time marked read |
| timestamps | utc_datetime | |

- Unique: `(user_id, entry_id)`
- Check: unread ⇒ `read_at IS NULL`; read ⇒ `read_at IS NOT NULL`
- Partial indexes for unread, starred, and cleanup-by-`read_at`

## Application config keys

```elixir
config :earss, :refresh,
  min_interval: 15,
  max_interval: 10_080,
  default_interval: 30

config :earss, :retention,
  read_state_days: 90,
  entry_days: 180,
  unsubscribed_feed_days: 30
```

These must stay aligned with column defaults where applicable (especially **D7**).

## Out of scope tables

Intentionally **not** in v1: `enclosures`, favicons, sessions/API tokens, permissions, OPML import jobs, `subscriber_count` cache columns.

## Version

- Tag: `db-schema-v1`
- Frozen with the default decision set (2026-07)
