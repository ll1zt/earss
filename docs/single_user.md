# Single-user architecture

> **Status: implemented (C1–C6 complete).** Milestone: **`db-schema-v2`**
> (the roadmap's reserved path for replacing the `db-schema-v1` freeze).
> The implementation commit sequence follows the C1–C5 plan below; see the
> git history on `refactor/single-user` for the atomic steps.

Earss is currently a multi-user reader: global content (`feeds`/`entries`,
"one crawl, many readers") plus a per-user graph (`users`,
`subscriptions`, `categories`, `entry_states`). This document plans the
conversion to a **single-operator** deployment and the removal of the
per-user dimension from the data model, context APIs, authentication, and
admin UI.

## Locked decisions

| # | Decision | Choice |
|---|----------|--------|
| D1 | Scope | **Full single-user**: drop the `users` table, remove `user_id` from the three state tables, strip `%User{}` from the Reader context, downgrade auth to single-operator credentials |
| D2 | Auth | **Keep protection**: Admin session login with a single password (`ADMIN_PASSWORD`), JSON API keeps a global signed token, Fever keeps an `api_key` parameter checked against a fixed `FEVER_API_KEY` (the Fever protocol requires the parameter; NetNewsWire compatibility must not change) |
| D3 | Translation | **Feed-level only**: remove `subscriptions.translate_to` / `original_layout`; `languages_for_feed` collapses to `feed.translate_to`; the per-subscription override concept and its M1 "global visibility window" semantics disappear |
| D4 | Existing data | **Migrate**: `db-schema-v2` migration keeps the first (admin) user's subscriptions/categories/entry states and drops other users' rows |

## Coupling inventory (today)

| Layer | Coupling | Size |
|-------|----------|------|
| Schema | `users`; `subscriptions`/`categories`/`entry_states` carry `user_id` FK (cascade delete) + unique constraints `(user_id, feed_id)` / `(user_id, name)` / `(user_id, entry_id)` | 4 tables |
| Context | `Earss.Reader` facade: 35 functions take `%User{}`; `Reader.Users` (174 lines) | ~40 functions |
| Auth | JSON Bearer token (`api/token.ex`), Admin session (`admin/auth.ex`), Fever api key (`reader/users.ex`), GReader ClientLogin | 4 modules |
| Protocols | GReader/Fever resolve the user per request; `sub_translate_to` / `original_layout` per row from the subscription; `user/-/state/...` stream-id prefixes (protocol format, kept) | whole protocol layer |
| Admin | 45 `admin_user` / `sub_user` / `user_type` check sites; `with_user` wraps every action | 12 controllers |
| Translation | `languages_for_feed` aggregates overrides from all users' subscriptions | 1 core site |
| Export/OPML | per-user scopes; admin-only full archive | 2 modules |
| Tests | 53 `create_user`/`insert_user` references across 17 files | large |

## What stays unchanged

- `feeds` / `entries` / `entry_translations` (global content layer — already
  single-user shaped)
- Scheduler, pollers, retention, host politeness, source plugins
- Fever / GReader **wire format** (no user concept in the output; NetNewsWire
  compatibility unchanged)
- Feed-level translation config and the four original-text layouts

## Implementation plan (atomic commits — all done)

### C1 `refactor(reader)!: drop per-user parameters from Reader context`

- Strip `%User{}` from the `Earss.Reader` facade (35 signatures): categories,
  subscriptions, entry states, timeline, OPML, Fever queries
- Delete `reader/users.ex` and `reader/user.ex`
- Protocol queries (greader streams/items, fever queries) lose the user join
- Export/OPML lose user arguments
- Ecto schemas keep the `user_id` fields until the migration lands (C5) so
  each intermediate commit stays green

### C2 `refactor(auth)!: single-operator auth (password, token, fever key)`

- Admin session: single password from `ADMIN_PASSWORD` (earss.env), no user
  row lookup
- JSON API: global token (single-key signature, no user payload)
- Fever: fixed `FEVER_API_KEY` env check
- `Earss.Bootstrap` validates config instead of seeding a default admin

### C3 `refactor(translate)!: feed-level only translation config`

- Remove `subscriptions.translate_to` / `original_layout` (schema, admin
  forms, protocol rows)
- `languages_for_feed` collapses to the feed's `translate_to`
- `Earss.API.Translation` simplifies: target language and layout always
  resolve from the feed
- M1's "one reader's override hides entries for everyone" semantics
  disappear by construction

### C4 `refactor(admin)!: drop sub_user permission model`

- Remove the 45 `user_type` / `sub_user` check sites; `with_user` →
  `with_login` (single operator, no role)
- Admin views drop user display

### C5 `feat(schema)!: db-schema-v2 single-user migration`

- `subscriptions`: drop `user_id` (unique → `(feed_id)`)
- `categories`: drop `user_id` (unique → `(name)`)
- `entry_states`: drop `user_id` (unique → `(entry_id)`)
- `subscriptions`: drop `translate_to` / `original_layout`
- **Drop `users`** (including `fever_api_key` column)
- Data migration: keep the first admin user's rows, delete other users'
  subscriptions/categories/entry states (per D4)
- `down` restores the v1 shape (documented as best-effort: dropped user rows
  are not recoverable)

### C6 `docs: db-schema-v2 milestone`

- Update `architecture.md`, `data_model.md`, `roadmap.md`, `translate.md`
  (drop the subscription-override sections), `earss.env.example`
  (`ADMIN_PASSWORD`, `FEVER_API_KEY`), `docs/backup.md` notes
- Tag `db-schema-v2` at the milestone commit

## Risks

1. **Data migration** (D4): the v2 migration must pick a keeper user (first
   `admin` by `id`), re-home its rows, and delete the rest — destructive and
   hard to roll back for the dropped users' rows
2. **Test rewrite volume**: 53 user references (mostly mechanical parameter
   removal) across 17 files
3. **Translation semantics change**: per-subscription overrides disappear —
   `?original=1` and layouts follow the feed only; translate.md and the
   admin UI must be updated in the same change
4. **Protocol auth**: Fever clients send the operator's api key; changing
   `FEVER_API_KEY` requires re-configuring clients (document in deploy docs)
