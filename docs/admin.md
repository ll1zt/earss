# Web Admin (`admin-v0.3`)

Server-rendered HTML console for **source management and ops visibility**.  
**Reading** is intended via NetNewsWire (or another client), not this UI:

- [Fever API](fever.md) — account type **Fever**, URL `http://HOST:PORT/fever/`
- [FreshRSS / GReader](greader.md) — account type **FreshRSS**, URL `http://HOST:PORT/api/greader.php`

Dashboard shows unread totals from the same lazy-state rules as Admin subscriptions. If Admin unread ≠ NNW, see the troubleshooting section in [greader.md](greader.md).

**Plugin sources** (`earss://…`, e.g. Telegram): subscribe today via IEx / API / OPML URL paste. There is no Admin “plugin catalog” yet (roadmap **S5**). See [sources.md](sources.md).

## UI themes

Two built-in themes (session only, no rebuild):

| Id | Name | Feel |
|----|------|------|
| `crt` | **CRT** (default) | Terminal / BBS — green phosphor, mono, hard edges, light scanlines |
| `paper` | **Paper** | Warm newsprint — cream paper, serif, red panel headers |

Switch from the top bar or login page: `POST /admin/theme` with `theme=crt|paper` (+ CSRF). Stored as session key `admin_theme`. Implementation: `Earss.Admin.Theme` + CSS in `Earss.Admin.HTML`.

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

## CSRF

All state-changing Admin forms include a `_csrf_token` field (`Plug.CSRFProtection`).  
GET requests issue/refresh the token; POSTs without a valid token are rejected (redirect + flash).  
Login and logout forms are protected as well.

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
- Changing application config from the UI (System is **read-only** for config)
