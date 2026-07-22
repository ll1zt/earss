# Web Admin (`admin-v0.1`)

Server-rendered HTML console for managing sources and account.  
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

| Area | Paths |
|------|--------|
| Login / logout | `/admin/login`, `POST /admin/logout` |
| Dashboard | `/admin` — subscription/unread counts + NNW URL hints |
| Subscriptions | list, add URL, hide, unsubscribe, set category, unread count |
| Categories | create / delete |
| Feeds | refresh, re-enable circuit-breaker |
| OPML | paste import, download export |
| Settings | change login password, set Fever-only secret |

## Session

Cookie session (`Plug.Session`), signed with `config :earss, :api, :secret_key_base`.

## First user

```elixir
iex -S mix
{:ok, _} = Earss.Reader.create_user("admin", "secret")
```

Then open `/admin` and sign in.

## Not in scope (v0.1)

- Full web reader UI
- Multi-user admin UI for creating users (use iex / future)
- CSRF tokens (add before exposing to untrusted networks without reverse-proxy auth)
