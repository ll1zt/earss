# Architecture

## What Earss is

Earss is a **self-hosted feed reader backend**. It is not a full web UI. The long-term shape is:

1. Ingest RSS / Atom / JSON Feed sources on a schedule
2. Store article content **once per source**
3. Expose per-user subscriptions, categories, and read/star state
4. (Later) serve an HTTP/JSON API for clients

The project is an OTP application (`Earss.Application`) that currently supervises only `Earss.Repo`. There is no Phoenix endpoint yet.

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

Owns identity and personalization.

- Users (`admin` / `sub_user`), password hashing (Argon2)
- Categories, subscriptions, entry states
- On unsubscribe: delete that user’s states for the feed’s entries; update zero-subscriber bookkeeping on the feed

Cross-context rules are documented in [data_lifecycle.md](data_lifecycle.md). Prefer explicit function calls over DB triggers.

## Runtime (today)

```
Earss.Supervisor
  └── Earss.Repo
```

Planned (not implemented):

```
Earss.Supervisor
  ├── Earss.Repo
  ├── Oban (or FeedPoller GenServer)
  └── (optional) web endpoint
```

## Configuration surface

| Key | Role |
|-----|------|
| `Earss.Repo` | Database connection |
| `:earss, :refresh` | Default min / max / default fetch intervals (minutes) |
| `:earss, :retention` | Cleanup windows (days) |

See [data_model.md](data_model.md) for exact defaults (decision **D7** and retention).

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
