# Fever API compatibility (`fever-v0.1`)

> 📖 Operator setup (NetNewsWire account fields): [User guide → Connect your reader](usage.md).

Earss exposes a **Fever-compatible** endpoint for clients such as **NetNewsWire**.

## Endpoint

```
POST /fever/?api
GET  /fever/?api   (also accepted)
```

Form body or query string parameters (classic Fever style).

## Auth

Classic Fever:

Single-operator mode: the expected key is the fixed `FEVER_API_KEY` from
earss.env (constant-time check — no users table, no MD5 derivation).

NetNewsWire:

1. Account type: **Fever**
2. URL: `http://HOST:PORT/fever/`
3. Username: anything (e.g. `earss`)
4. Password / API key: the value of `FEVER_API_KEY`

Response always includes:

```json
{ "api_version": 3, "auth": 1 }
```

or `"auth": 0` when the key is wrong.

## Supported actions

| Request flags | Behaviour |
|---------------|-----------|
| *(none extra)* | auth only |
| `groups` | categories (+ virtual group 0 “Uncategorized” is not always required; we emit real categories); includes `feeds_groups` |
| `feeds` | subscriptions as feeds; includes `feeds_groups` (Fever spec: either flag returns relationships) |
| `groups` + `feeds` | groups + feeds + `feeds_groups` |
| `favicons` | empty list (placeholder) |
| `items` | items; optional `since_id`, `max_id`, `with_ids`; `total_items` is full visible count (not page size) |
| `unread_item_ids` | comma-separated unread entry ids |
| `saved_item_ids` | starred entry ids |
| `mark=item&as=read&id=` | mark read |
| `mark=item&as=unread&id=` | mark unread |
| `mark=item&as=saved&id=` | star |
| `mark=item&as=unsaved&id=` | unstar |
| `mark=feed&as=read&id=&before=` | mark feed read (`before` unix optional) |
| `mark=group&as=read&id=&before=` | mark category read (`id=0` → all uncategorized / all) |

## Not supported (empty / no-op)

- `links`, Hot Links / sparcs
- favicons content
- unread_item_ids size limits for huge libraries (personal use)

## Mapping

| Fever | Earss |
|-------|--------|
| group | `categories` |
| feed | `subscriptions` + `feeds` |
| item | `entries` + `entry_states` |
| saved | `is_star` |
| unread | no state or `is_read=false` |

## Implementation

- `Earss.Fever` — domain assembly
- `Earss.API.Fever` — Plug endpoint
- Mounted from `Earss.API.Router` at `/fever`

## Testing

```bash
mix test test/earss/fever_test.exs
```

Manual:

```bash
# api_key=$(echo -n 'user:secret' | md5)
curl -s -X POST 'http://localhost:4000/fever/?api' \
  -d "api_key=$API_KEY&groups&feeds"
```
