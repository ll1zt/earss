# HTTP API (`api-v0.1` / `api-v1`)

Plug + Bandit JSON API. No Phoenix.

**OpenAPI 3.1 contract:** [openapi.yaml](openapi.yaml) (JSON API only; Fever / GReader stay in their own docs).

## Run

```bash
iex -S mix
# listens on port 4000 by default (config :earss, :api)
```

```elixir
# create a user once
{:ok, _} = Earss.Reader.create_user("admin", "secret")
```

## Auth

```bash
curl -s -X POST http://localhost:4000/api/auth/login \
  -H 'content-type: application/json' \
  -d '{"username":"admin","password":"secret"}'
# => {"token":"...","user":{...}}
```

Send on protected routes:

```http
Authorization: Bearer <token>
```

Tokens are **signed** (`Plug.Crypto`); not stored server-side.  
Configure `secret_key_base` / `SECRET_KEY_BASE` in production.

## Endpoints

| Method | Path | Auth | Notes |
|--------|------|------|--------|
| GET | `/health` | no | liveness |
| POST | `/api/auth/login` | no | `{username,password}` |
| GET | `/api/me` | yes | current user |
| GET/POST | `/api/categories` | yes | list / create |
| PATCH/DELETE | `/api/categories/:id` | yes | |
| GET/POST | `/api/subscriptions` | yes | POST body: `link` or `feed_id`, optional `refresh` |
| PATCH/DELETE | `/api/subscriptions/:id` | yes | DELETE unsubscribes |
| GET | `/api/entries` | yes | query: `unread`, `starred`, `feed_id`, `category_id`, `limit`, `offset` |
| POST | `/api/entries/:id/read` | yes | |
| POST | `/api/entries/:id/unread` | yes | |
| POST | `/api/entries/:id/star` | yes | |
| DELETE | `/api/entries/:id/star` | yes | |
| POST | `/api/feeds/:id/refresh` | yes | must be subscribed |
| POST | `/api/entries/mark_read` | yes | body: `{ids:[...]}` or `{feed_id:n}` |
| GET | `/api/subscriptions?with_unread_count=true` | yes | default includes `unread_count` |
| GET | `/api/opml/export` | yes | OPML XML body |
| POST | `/api/opml/import` | yes | `{opml:"...", refresh:false}` |

## Examples

```bash
TOKEN=...

curl -s http://localhost:4000/api/me -H "Authorization: Bearer $TOKEN"

curl -s -X POST http://localhost:4000/api/subscriptions \
  -H "Authorization: Bearer $TOKEN" \
  -H 'content-type: application/json' \
  -d '{"link":"https://example.com/feed.xml","refresh":true}'

curl -s 'http://localhost:4000/api/entries?unread=true' \
  -H "Authorization: Bearer $TOKEN"

curl -s -X POST http://localhost:4000/api/entries/mark_read \
  -H "Authorization: Bearer $TOKEN" \
  -H 'content-type: application/json' \
  -d '{"feed_id":1}'

curl -s -X POST http://localhost:4000/api/opml/import \
  -H "Authorization: Bearer $TOKEN" \
  -H 'content-type: application/json' \
  -d @- <<'EOF'
{"opml":"<?xml version=\"1.0\"?><opml version=\"2.0\"><body><outline type=\"rss\" xmlUrl=\"https://example.com/feed.xml\" text=\"Ex\"/></body></opml>","refresh":false}
EOF

curl -s http://localhost:4000/api/opml/export -H "Authorization: Bearer $TOKEN"
```

## Config

```elixir
config :earss, :api,
  enabled: true,
  port: 4000,
  secret_key_base: "...",
  token_max_age_secs: 60 * 60 * 24 * 30
```

Test env: `enabled: false` (router still unit-tested via `Plug.Test`).
