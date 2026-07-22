# Data lifecycle (`db-schema-v1`)

Companion to [data_model.md](data_model.md).

Business contexts **must** implement the side effects below.  
**No database triggers** in this milestone—behavior lives in application code.

## 1. Users

| Event | Behavior |
|-------|----------|
| Create `admin` / `sub_user` | Store `password_hash`; valid `user_type`; default `is_active = true` |
| Disable | Set `is_active = false`; authentication must fail |
| Delete user | FK cascades categories, subscriptions, entry_states; for each formerly subscribed feed, if subscriber count hits zero, set `last_unsubscribed_at` |

## 2. Categories

| Event | Behavior |
|-------|----------|
| Create | `(user_id, name)` unique; optional `position` |
| Delete | Child subscriptions get `category_id = NULL` (still visible under **all**) |

## 3. Subscriptions

| Event | Behavior |
|-------|----------|
| Subscribe | Create feed if missing; insert subscription; **clear** `feed.last_unsubscribed_at`; preferably set `next_fetch_at` to “now” for a fast first fetch |
| Unsubscribe | Delete this user’s `entry_states` for that feed’s entries; delete subscription; if the feed has no remaining subscriptions → `last_unsubscribed_at = utc_now()` |
| Hide | `is_hidden = true`: may hide in UI lists but **still counts as a subscriber** (crawl continues). **Hidden subscriptions do not participate** in D1 min-interval aggregation |

## 4. Feed fetch field contract (implementation phase)

| Outcome | Field updates (contract) |
|---------|---------------------------|
| Success, new content | `last_fetched_at`, `next_fetch_at`, `error_count = 0`, `last_error = null`, `unchanged_fetch_count = 0`, shrink `refresh_interval`, refresh etag/hash, set `last_new_entry_at` |
| Success, no new content | Like success, but `unchanged_fetch_count++` and lengthen interval |
| HTTP 304 / same hash | Treat as no new content |
| Failure | `error_count++`, set `last_error`, back off `next_fetch_at`; after threshold may set `is_active = false` |

**Due feeds query (conceptual):**

```text
is_active = true
AND next_fetch_at <= now()
AND EXISTS (subscription for feed)
AND last_unsubscribed_at IS NULL
```

`last_unsubscribed_at IS NULL` and `EXISTS (subscription)` should agree; use one as primary and the other as a guardrail.

## 5. Entry writes

- Normalize `guid`: trim; if empty use `link`; if still empty drop the item.
- Upsert on `(feed_id, guid)` updating mutable fields: `title`, `author`, `summary`, `content`, `link`, `published_at`, `content_hash`.
- Never rewrite existing `entry_states` because content changed.

## 6. Reading state (lazy creation)

| Event | Behavior |
|-------|----------|
| Mark read | Upsert state: `is_read = true`; set `read_at` if missing (first-read timestamp) |
| Mark unread | Upsert: `is_read = false`, `read_at = null` |
| Star / unstar | Upsert `is_star` |
| Never touched | No row; list UIs treat as unread |

## 7. Cleanup jobs

### Level A — delete expired states

```text
is_read = true
AND is_star = false
AND read_at < now() - retention.read_state_days   -- default 90
```

### Level B — delete reclaimable entries

Run after Level A. Delete entries that satisfy **all** of:

1. No state with `is_star = true`
2. No state with `is_read = false`
3. `inserted_at < now() - retention.entry_days` (default **180**)

**Forbidden:** delete an entry solely because it has zero `entry_states` while still inside the retention window.

### Zero-subscriber feeds

```text
last_unsubscribed_at IS NOT NULL
AND last_unsubscribed_at < now() - retention.unsubscribed_feed_days  -- default 30
→ DELETE feed (cascades entries, etc.)
```

## 8. Cascade summary

| Delete | Result |
|--------|--------|
| `user` | `categories`, `subscriptions`, `entry_states` |
| `feed` | `entries`, `subscriptions` (and entry → states) |
| `entry` | `entry_states` |
| `category` | `subscriptions.category_id = NULL` |

## 9. Phase boundary

Rules in this document are frozen for **`db-schema-v1`**.  
`Earss.Feeds` business logic, the scheduler runtime, and cleanup workers ship later—but they must not violate this contract.
