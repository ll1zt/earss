# Web Admin (`admin-v0.2`)

Server-rendered HTML console for **source management and ops visibility**.  
**Reading** is intended via NetNewsWire (or another client), not this UI:

- [Fever API](fever.md) — account type **Fever**, URL `http://HOST:PORT/fever/`
- [FreshRSS / GReader](greader.md) — account type **FreshRSS**, URL `http://HOST:PORT/api/greader.php`

Dashboard shows unread totals from the same lazy-state rules as Admin subscriptions. If Admin unread ≠ NNW, see the troubleshooting section in [greader.md](greader.md).

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
| Subscription detail | `/admin/subscriptions/:id` | title, interval, category, hidden; feed read-only + refresh |
| Categories | create, **rename / position**, delete, sub counts | |
| Feeds | health table, status filters, single + **batch refresh** | Batch max **20** |
| System | `/admin/system` | Config snapshot, due feeds, retention dry_run/run — **`admin` only** |
| OPML | paste import, download export | |
| Settings | login password, Fever-only secret | |

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
- Only `user_type == "admin"`; `sub_user` is redirected to the dashboard
- Uses `Earss.Retention.run_all/1` (Level A → B → C)

## Session

Cookie session (`Plug.Session`), signed with `config :earss, :api, :secret_key_base`.

## First user

```elixir
iex -S mix
{:ok, _} = Earss.Reader.create_user("admin", "secret")
```

Then open `/admin` and sign in.

## Permissions

| Action | `admin` | `sub_user` |
|--------|---------|------------|
| Own subscriptions / categories / OPML / settings | ✓ | ✓ |
| Refresh / re-enable subscribed feeds | ✓ | ✓ |
| Global due snapshot + retention | ✓ | ✗ |
| Refresh feed not subscribed (admin path) | ✓ | ✗ |

## Not in scope

- Full web reader UI
- Multi-user admin UI for creating users (use iex / future)
- CSRF tokens (add before exposing to untrusted networks without reverse-proxy auth)
- Changing application config from the UI (System is **read-only** for config)
