# Google Reader API (FreshRSS / NetNewsWire)

Earss implements a **subset of the Google Reader API** compatible with clients that speak FreshRSS’s `greader.php` protocol—including **NetNewsWire → Add Account → FreshRSS**.

## Base URL

```
http://HOST:PORT/api/greader.php
```

NetNewsWire will append paths such as `/accounts/ClientLogin` and `/reader/api/0/...`.

## Auth

### ClientLogin

```http
POST /api/greader.php/accounts/ClientLogin
Content-Type: application/x-www-form-urlencoded

Email=USERNAME&Passwd=PASSWORD
```

Response (text):

```
SID=<token>
LSID=<token>
Auth=<token>
```

Subsequent requests:

```http
Authorization: GoogleLogin auth=<token>
```

Password may be:

- the **login password**, or  
- the **Fever-only secret** from Admin → Settings (same `md5` secret used for Fever)

## Implemented endpoints

| Path | Notes |
|------|--------|
| `accounts/ClientLogin` | username/password → Auth token |
| `reader/api/0/token` | edit token (signed) |
| `reader/api/0/user-info` | basic profile |
| `reader/api/0/subscription/list` | JSON subscriptions |
| `reader/api/0/tag/list` | labels + system tags |
| `reader/api/0/unread-count` | **required by NetNewsWire for badge counts** |
| `reader/api/0/stream/contents/*` | reading-list, feed/*, label/*, starred |
| `reader/api/0/stream/items/ids` | item id list (`s`, `n`, `xt`, `c`) |
| `reader/api/0/stream/items/contents` | items by `i=` |
| `reader/api/0/edit-tag` | mark read/unread/star (`a`/`r` + `i`) |
| `reader/api/0/mark-all-as-read` | stream `s` |

Query flags commonly used by NNW:

- `output=json` (always JSON for these handlers)
- `n` — count
- `c` — continuation
- `xt=user/-/state/com.google/read` — exclude read

## NetNewsWire setup

1. **File → Add Account… → FreshRSS**
2. **URL**: `http://127.0.0.1:4000/api/greader.php`  
   (no trailing path beyond `greader.php`; some builds want the directory form—if one fails, try with/without trailing slash)
3. **Username / Password**: Earss user + password (or Fever secret)
4. Add sources in **http://localhost:4000/admin** first (or OPML)

## Mapping

| GReader | Earss |
|---------|--------|
| `feed/<id>` | feed primary key (FreshRSS / NetNewsWire style) |
| `user/-/label/Name` | category name |
| `user/-/state/com.google/reading-list` | all subscribed entries |
| `user/-/state/com.google/starred` | starred |
| itemRefs `id` | **decimal** entry primary key |
| item atom id `/item/<hex>` | **hex** entry primary key (NNW contents/edit-tag) |

### NetNewsWire unread gotcha

NNW’s FreshRSS sync does **not** use `unread-count` alone for the badge. It:

1. Fetches article IDs (`stream/items/ids`)
2. Fetches bodies via `stream/items/contents` with **unpadded hex** `i=` values
3. Groups articles by `origin.streamId`, which must match subscription `id` (`feed/<numericId>`)

If `/item/<hex>` is parsed as decimal, or stream ids are feed URLs, NNW ends up with **no local articles** and shows unread **0** even when Admin is correct.

## Not implemented

- Full subscription/edit (add feed via API)—use Admin/OPML
- OPML via GReader
- search, friends, comments
- strict edit-token CSRF (token accepted loosely)

## Prefer Fever?

Fever (`/fever/`) is simpler and already supported. Use **FreshRSS/GReader** only if you want that account type in NNW or another GReader client.

## Tests

```bash
mix test test/earss/greader_test.exs
```
