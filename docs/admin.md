# Web Admin (`admin-v0.3`)

Server-rendered HTML console for **source management and ops visibility**.  
**Reading** is intended via NetNewsWire (or another client), not this UI:

- [Fever API](fever.md) — account type **Fever**, URL `http://HOST:PORT/fever/`
- [FreshRSS / GReader](greader.md) — account type **FreshRSS**, URL `http://HOST:PORT/api/greader.php`

Dashboard shows unread totals from the same lazy-state rules as Admin subscriptions. If Admin unread ≠ NNW, see the troubleshooting section in [greader.md](greader.md).

**Plugin sources** (`earss://…`): use **Sources** (`/admin/sources`) for registered adapters, route wizards, and URL subscribe. See [sources.md](sources.md).

## UI theme

Single **kami** (parchment) theme — warm canvas `#f5f4ed`, ink-blue accent
`#1B365D`, serif headings, warm-gray text. CSS lives in `priv/static/admin.css`
(served at `/static/admin.css`), no theme switcher. Implementation:
`Earss.Admin.HTML` layout + `Plug.Static` in `Earss.API.Router`.

## URL

With the API server running (`iex -S mix`, port 4000 by default):

```
http://localhost:4000/admin
```

`/` redirects to `/admin`.

## Features

| Area | Paths | Notes |
|------|--------|--------|
| Login / logout | `/admin/login`, `POST /admin/logout` | Session cookie |
| Dashboard | `/admin` | Clickable stats; problem / due lists |
| Subscriptions | list + filter, add URL, **detail edit** | See below |
| Subscription detail | `/admin/subscriptions/:id` | title, interval, category, hidden; feed read-only + refresh; source/adapter fields |
| Sources | `/admin/sources` | adapters, plugin routes, `earss://` / route-param subscribe (**S5**) |
| Categories | create, **rename / position**, delete, sub counts | |
| Feeds | health table, status filters, single + **batch actions** | Batch max **50** |
| Metrics | `/admin/metrics` | telemetry snapshot: fetch outcomes + latency, poller / translation / retention stats, recent failures |
| System | `/admin/system` | Config snapshot, due feeds, retention dry_run/run — **`admin` only** |
| OPML | paste import, download export | |
| Settings | login password, Fever-only secret | |

### Batch operations

Subscription / feed / category / translate tables offer a checkbox column
with a select-all header and a batch bar (CSRF-protected, results flashed):

| Page | Actions |
|------|---------|
| Subscriptions | refresh · hide · unhide · move to category · unsubscribe (confirmed) |
| Feeds | refresh · re-enable · disable |
| Categories | delete (confirmed) |
| Translate | re-translate paused · publish originals (confirmed) |

### Metrics (`/admin/metrics`)

In-memory aggregation of `Earss.Telemetry` events (no persistence, no extra
deps; resets on restart). Shows uptime, feed-fetch outcome counts and
avg/min/max latency, poller cycle totals, ingest-hook translation and
pending-worker stats, retention runs, and the most recent fetch failures.
`POST /admin/metrics/reset` clears counters (keeps uptime).

### Subscription filters (`GET /admin/subscriptions`)

| Query | Meaning |
|-------|---------|
| `q` | Title or feed URL substring |
| `category_id` | Category id, or `none` for uncategorized |
| `status` | `all` · `visible` · `hidden` · `error` · `disabled` · `due` |
| `sort` | `title` · `unread` · `next_fetch` · `id` |

### Feed filters (`GET /admin/feeds`)

| Query | Meaning |
|-------|---------|
| `q` | Title or URL |
| `status` | `all` · `active` · `disabled` · `error` · `due` |

### Retention (System)

- `POST /admin/system/retention` with `mode=dry_run` or `mode=run`
- Single-operator mode: one role — the operator
- Uses `Earss.Retention.run_all/1` (Level A → B → C)

## Session

Cookie session (`Plug.Session`), signed with `config :earss, :api, :secret_key_base`.

## CSRF

All state-changing Admin forms include a `_csrf_token` field (`Plug.CSRFProtection`).  
GET requests issue/refresh the token; POSTs without a valid token are rejected (redirect + flash).  
Login and logout forms are protected as well.

## Operator credentials

```elixir
iex -S mix
# single-operator mode: credentials come from ADMIN_PASSWORD (earss.env)
```

Then open `/admin` and sign in.

## Permissions

Single-operator mode: the operator has full access to every page and
action (no roles).

## Not in scope

- Full web reader UI
- Changing application config from the UI (System is **read-only** for config)
