# Google Reader API (FreshRSS / NetNewsWire)

Earss implements a **subset of the Google Reader API** compatible with clients that speak FreshRSS’s `greader.php` protocol—including **NetNewsWire → Add Account → FreshRSS**.

Verified against NetNewsWire’s ReaderAPI client (`stream/items/ids` → `stream/items/contents` sync path).

## Base URL

```
http://HOST:PORT/api/greader.php
```

Also accepted without `.php`:

```
http://HOST:PORT/api/greader
```

NetNewsWire appends paths such as `/accounts/ClientLogin` and `/reader/api/0/...`.

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
- the **Fever-only secret** from Admin → Settings (same MD5 secret used for Fever)

## Implemented endpoints

| Path | Notes |
|------|--------|
| `accounts/ClientLogin` | username/password → Auth token |
| `reader/api/0/token` | edit token (signed) |
| `reader/api/0/user-info` | basic profile |
| `reader/api/0/subscription/list` | JSON subscriptions (`feed/<id>`) |
| `reader/api/0/tag/list` | system tags + folders (`type=folder`) |
| `reader/api/0/unread-count` | reading-list + per-feed + per-label |
| `reader/api/0/stream/contents/*` | reading-list, feed/*, label/*, starred |
| `reader/api/0/stream/items/ids` | item id list (`s`, `n`, `xt`, `ot`, `c`) |
| `reader/api/0/stream/items/contents` | items by repeated `i=` form fields |
| `reader/api/0/edit-tag` | mark read/unread/star (`a`/`r` + repeated `i=`); requires `T` |
| `reader/api/0/mark-all-as-read` | stream `s`; requires `T` |
| `reader/api/0/subscription/edit` | `ac=subscribe\|unsubscribe\|edit` (`s`, optional `t`, `a=user/-/label/…`); requires `T` |

Query flags commonly used by NNW:

- `output=json`
- `n` — page size (ids default 1000)
- `c` — continuation (decimal entry id)
- `xt=user/-/state/com.google/read` — exclude read
- `ot` / `nt` — unix time bounds (seconds)

## Mapping

| GReader | Earss |
|---------|--------|
| `feed/<id>` | feed primary key (FreshRSS / NetNewsWire style) |
| `feed/<url>` | still accepted as a legacy stream id |
| `user/-/label/Name` | category name |
| `user/-/state/com.google/reading-list` | all subscribed entries |
| `user/-/state/com.google/starred` | starred |
| itemRefs `id` | **decimal** entry primary key |
| item atom id `tag:…/item/<hex>` | **hex** entry primary key (NNW contents/edit-tag) |
| `origin.streamId` | must equal subscription `id` (`feed/<id>`) |

## NetNewsWire setup

1. **File → Add Account… → FreshRSS**
2. **URL**: `http://127.0.0.1:4000/api/greader.php`  
   (no extra path after `greader.php`; if one build fails, try with/without trailing slash)
3. **Username / Password**: Earss user + password (or Fever secret)
4. Add sources in **http://localhost:4000/admin** first (or OPML)
5. Force refresh after server upgrades; if the sidebar is empty, remove and re-add the account once

## How NetNewsWire sync works

NNW’s FreshRSS path does **not** rely on `unread-count` alone for the badge. Typical refresh:

1. `subscription/list` + `tag/list` — build sidebar feeds/folders
2. `stream/items/ids` on reading-list (`ot` ≈ last fetch or ~3 months)
3. `stream/items/ids` with `xt=…/read` — server unread ids
4. `stream/items/contents` — POST many `i=tag:google.com,2005:reader/item/<unpadded-hex>`
5. Local DB stores articles keyed by feed stream id, then applies unread/star status

### Response contracts that matter for NNW

| Response | Requirement |
|----------|-------------|
| `subscription/list` | each sub `id` is `feed/<numericId>`; `url` / `htmlUrl` present |
| `tag/list` | labels use `user/-/label/…` and `type: "folder"` for categories |
| `stream/items/ids` | `itemRefs[].id` is **decimal** string; optional `continuation` only on full pages |
| `stream/items/contents` | top-level **`id` + `updated` (unix sec) + `items`** — NNW fails the whole decode if `updated` is missing |
| each item | `id` atom form, `origin.streamId` = `feed/<id>`, `summary.content`, optional `crawlTimeMsec` / `timestampUsec` |
| form posts | repeated keys (`i=`, `a=`, `r=`) are all collected (not collapsed to last value) |

### Item id rules

| Context | Encoding | Example for entry `51` |
|---------|----------|-------------------------|
| `itemRefs` | decimal | `"51"` |
| NNW → contents `i=` | unpadded hex | `tag:…/item/33` (`0x33 == 51`) |
| item JSON `id` | 16-digit padded hex atom | `tag:…/item/0000000000000033` |

`/item/<hex>` is **always** parsed as hex. Bare numeric strings without `/item/` stay decimal for itemRefs.

### Time bounds (`ot`)

- NNW often sends `ot` ≈ “now” as a watermark on full-list sync.
- Earss ignores `ot` values within **5 minutes of now** (and future values).
- Unread id sync (`xt=read`) **never** applies `ot`, so already-ingested unread items stay visible.
- Item **display** timestamps use `published_at` (fallback `inserted_at`); `crawlTimeMsec` is ingest time.
- Stream `ot`/`nt` bounds still use `GREATEST(published_at, inserted_at)` so newly crawled older articles remain in the watermark window.

## Troubleshooting (Admin unread ≠ NNW)

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Admin shows unread, NNW badge 0 | contents decode / id mismatch (older builds) | upgrade server; re-add account |
| Sidebar has no feeds | local unread 0 + “Hide Read Feeds”, or stale account cache | turn off hide-read; re-add account |
| Only 1 article ever syncs | repeated `i=` collapsed by form parser | needs multi-value form support (current code) |
| Wrong articles / empty bodies | `/item/33` parsed as decimal 33 | hex parse for `/item/*` |
| Feeds not attached | `origin.streamId` was URL-based | use `feed/<id>` |

Useful server logs:

```text
GReader items/ids stream=… n=51
GReader items/contents requested=51 …
GReader items/contents returned=51
```

If `requested` ≪ `n` from ids, form multi-value parsing is broken.  
If `returned` is 0 while `requested` is high, hex id parsing is wrong.

## Not implemented

- OPML via GReader
- search, friends, comments
- subscription/edit renames beyond title/folder (no multi-label)

## Edit token

Mutating endpoints (`edit-tag`, `mark-all-as-read`, `subscription/edit`) require `T` from `reader/api/0/token`. The auth token is also accepted as `T` for client compatibility.

## Prefer Fever?

Fever (`/fever/`) is simpler and already supported. Use **FreshRSS/GReader** only if you want that account type in NNW or another GReader client.

## Tests

```bash
mix test test/earss/greader_test.exs
```

Coverage includes ClientLogin, subscription list, unread-count, decimal itemRefs, hex `/item/` parse, multi-value `i=` form posts, and `updated` on contents.
