# Feed scheduler design guide

> **Status:** Implemented for MVP — see `Earss.FeedScheduler` and `Earss.FeedPoller`.  
> Aligned with [data_model.md](data_model.md) / [data_lifecycle.md](data_lifecycle.md).

## Goals

- Per-subscription optional refresh preference (`custom_refresh_interval`)
- Per-feed adaptive interval (`refresh_interval` slides between min and max)
- Exponential backoff on failure; disable feed after repeated errors (`is_active = false`)
- Exactly **one** crawl pipeline per feed URL globally

## Modules

| Module | Role |
|--------|------|
| `Earss.FeedScheduler` | Pure interval math, D1 effective interval, `list_due_feeds/1`, `initialize_next_fetch/1` |
| `Earss.Feeds.Fetcher` | Calls `FeedScheduler.schedule_attrs/3` after each outcome |
| `Earss.FeedPoller` | GenServer tick → due feeds → `Feeds.refresh/1` with concurrency |
| `Feeds.refresh/1` | Manual / force refresh entry point |

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

## Effective interval (D1)

```text
candidates =
  [feed.refresh_interval]
  ++ custom_refresh_interval from subscriptions
       where is_hidden = false
         and custom_refresh_interval is not null

effective = clamp(min(candidates), min_refresh_interval, max_refresh_interval)
```

If the feed has **no subscribers**, `list_due_feeds` excludes it (poller will not refresh).

## Adaptive policy

| Scenario | Policy |
|----------|--------|
| Success + new content (hash changed / entries upserted) | `refresh_interval *= 0.9`, clamp |
| Success + no new content (304 / same hash / empty entries) | `refresh_interval *= 1.2`, clamp |
| Failure | Backoff `2^(error_count-1)` (cap 32×) on wait time; keep stored interval |
| Failures ≥ **5** | `is_active = false` |

## Selecting due feeds

```elixir
FeedScheduler.list_due_feeds(limit \\ 50)
# is_active, next_fetch_at due or nil, last_unsubscribed_at nil,
# exists subscription
```

## Poller configuration

```elixir
config :earss, :poller,
  enabled: true,                 # false in test
  interval_ms: 5 * 60 * 1000,
  batch_size: 50,
  max_concurrency: 5
```

## Console tips

```elixir
alias Earss.{Feeds, FeedScheduler, Reader}

{:ok, feed} = Feeds.ensure_feed("https://example.com/feed.xml")
# Until Reader.subscribe exists, insert a subscription row so the poller picks it up,
# or call Feeds.refresh(feed) manually.

FeedScheduler.initialize_next_fetch(feed)
FeedScheduler.list_due_feeds()
Earss.FeedPoller.poll_now()  # if poller is running
```

## Future

- Oban instead of / in addition to GenServer
- Finer “new content” detection (per-guid insert vs update counts)
