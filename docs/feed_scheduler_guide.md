# Feed scheduler design guide

> **Status:** Design frozen and aligned with [data_model.md](data_model.md) / [data_lifecycle.md](data_lifecycle.md).  
> **`db-schema-v1` does not require** an `Earss.FeedScheduler` module to exist yet.

## Goals

- Per-subscription optional refresh preference (`custom_refresh_interval`)
- Per-feed adaptive interval (`refresh_interval` slides between min and max)
- Exponential backoff on failure; disable feed after repeated errors (`is_active = false`)
- Exactly **one** crawl pipeline per feed URL globally

## Field names (authoritative)

| Purpose | Column |
|---------|--------|
| Current interval | `refresh_interval` |
| Bounds | `min_refresh_interval` / `max_refresh_interval` |
| Next run | `next_fetch_at` |
| Quiet streak | `unchanged_fetch_count` |
| Error streak | `error_count` |
| Circuit breaker | `is_active` |
| HTTP cache | `etag`, `last_modified`, `last_fetched_content_hash` |
| Zero subs | `last_unsubscribed_at` |

Do not use shortened names like `min_interval` in code—those exist only under `config :earss, :refresh`.

## Effective interval (D1)

```text
candidates =
  [baseline interval used by adaptive logic]
  ++ custom_refresh_interval from subscriptions
       where is_hidden = false
         and custom_refresh_interval is not null

effective = clamp(
  min(candidates),
  feed.min_refresh_interval,
  feed.max_refresh_interval
)
```

If the feed has **no subscribers**, do not schedule it.

## Adaptive policy (recommended)

| Scenario | Policy |
|----------|--------|
| Success + new content | `refresh_interval *= 0.9`, not below min |
| Success + no new content | `refresh_interval *= 1.2`, not above max |
| Failure | Backoff `2^n` (cap e.g. 32×), write `last_error` |
| Failures ≥ threshold (suggest **5**) | `is_active = false` |

Exact multipliers can be tuned later; persistence fields already support the policy.

## Selecting due feeds

```elixir
# Pseudocode
from f in Feed,
  where: f.is_active == true,
  where: f.next_fetch_at <= ^now,
  where: is_nil(f.last_unsubscribed_at),
  where:
    fragment(
      "exists (select 1 from subscriptions s where s.feed_id = ?)",
      f.id
    ),
  order_by: [asc: f.next_fetch_at],
  limit: ^limit
```

## Configuration

```elixir
config :earss, :refresh,
  min_interval: 15,
  max_interval: 10_080,   # minutes (7 days)
  default_interval: 30
```

New feeds should initialize `refresh_interval` / min / max from these defaults unless overridden.

## Integration options (next phase)

### Oban (preferred for production-shaped apps)

- Cron every few minutes enqueues a batch worker
- Bounded concurrency on a `:feeds` queue
- Per-job timeouts and retries separate from feed-level `error_count`

### GenServer poller (fine for MVP)

- Periodic `handle_info` loads due feeds
- `Task.async_stream` with `max_concurrency`
- Must not block the scheduler process on slow HTTP

## API sketch (future module)

Suggested functions (names illustrative):

| Function | Role |
|----------|------|
| `initialize_next_fetch/1` | Set initial `next_fetch_at` (often “now”) |
| `get_feeds_to_fetch/1` | Due feed query |
| `calculate_next_fetch/2` | Pure interval math (success / no content / error, optional custom interval) |
| `update_fetch_status/2` | Persist outcome + next run |

Implementations must use the real column names from this guide.

## Out of scope here

- Actual HTTP client and XML/JSON parsers
- Content extraction / sanitization
- User-facing “force refresh” API (will call into the same status update path)
