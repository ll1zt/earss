# Source adapters & plugins

**Status:** design / not implemented  
**Decisions locked for this design:** **R1** (`earss://` URLs) · **C2** (separate `earss_source` contract package)

This document is the source of truth for how Earss will support sites **without native RSS/Atom/JSON Feed**, via **independently maintained plugins**, without embedding site-specific scrapers in the core app.

Related:

- Shared crawl model: [architecture.md](architecture.md), [data_model.md](data_model.md)
- Fetch lifecycle: [data_lifecycle.md](data_lifecycle.md)
- Scheduling: [feed_scheduler_guide.md](feed_scheduler_guide.md)
- Implementation order: [roadmap.md](roadmap.md) (Phase S)

---

## 1. Goals

| Goal | Detail |
|------|--------|
| Extend beyond RSS | Ingest content from HTML sites, JSON APIs, etc. |
| Plugin-shaped | Site logic lives in **separate Mix packages**, optional at deploy time |
| Weak coupling to Earss | Plugins depend on a **small contract package** (`earss_source`), not private Earss modules |
| Reuse core | Same shared `feeds`/`entries`, poller, retention, Admin, Fever, GReader |
| Safe default | Stock Earss with **no plugins** behaves exactly as today |

### Non-goals (this design)

- Shipping a large built-in route catalog (RSSHub-style monolith)
- Runtime download/eval of untrusted code
- Browser automation inside core
- Per-user crawl credentials that break “one crawl, many readers”
- Full compatibility with RSSHub path names or Node middleware

You can still point Earss at a self-hosted RSSHub (or any feed URL) using the **native** HTTPS path—no plugin required.

---

## 2. Locked product decisions

### R1 — Canonical plugin URLs use `earss://`

```
earss://<adapter_id>/<route_and_params...>
```

Examples:

```
earss://bilibili/user/123456
earss://github/releases/elixir-lang/elixir
https://example.com/feed.xml          # native only
```

Rules:

1. **`feeds.link`** remains the unique identity of a shared source (trimmed).
2. Plugin sources **must** use the `earss://` scheme so they never collide with real `http(s)` feed URLs.
3. `adapter_id` is the first path authority segment after the scheme (`bilibili` above). It must match the adapter’s `id/0`.
4. Path segments after `adapter_id` are **adapter-defined** route contracts. Core only does light parsing; semantic validation is `resolve/1`.
5. Changing scrape implementation **must not** change `source_url` if the logical route is the same (stable subscriptions / OPML).

Rejected alternatives:

- Fake `https://` hosts for plugins (ambiguous, breaks TLS mental model)
- Opaque random IDs as the only user-facing handle (bad UX for OPML / support)

### C2 — Contract package `earss_source`

| Package | Role |
|---------|------|
| **`earss_source`** | Behaviour, shared types, optional test helpers. **Semver-stable**, minimal deps. |
| **`earss`** | Core app. Depends on `earss_source`. Implements registry, native adapter, fetcher integration. |
| **`earss_source_*`** | Community or private plugins. Depend on **`earss_source` only** (not on `earss` internals). |

Rationale:

- Plugin authors can compile and unit-test against the contract without running full Earss.
- Earss can evolve private modules without breaking plugins that stayed on the behaviour surface.
- A future tiny “headless” consumer could reuse the same adapters.

If packaging overhead becomes painful before the first real plugin, an interim **in-tree** `Earss.Source` namespace may mirror the same modules, then extract—but the **public dependency graph for plugins must remain C2**.

---

## 3. Architecture

```
                    ┌──────────────────────┐
                    │  earss_source_*      │  (optional OTP apps)
                    │  register on start   │
                    └──────────┬───────────┘
                               │ Earss.Source.Registry.register/1
                               ▼
┌──────────────────────────────────────────────────────────────┐
│  earss                                                        │
│                                                               │
│  Reader.subscribe / Admin / OPML                              │
│         │                                                     │
│         ▼                                                     │
│  Feeds.ensure_feed(link, attrs)  →  feeds row                 │
│         │                                                     │
│  FeedPoller / Feeds.refresh                                   │
│         │                                                     │
│         ▼                                                     │
│  Feeds.Fetcher ──► Source.Resolver ──► Adapter.fetch/2        │
│         │                │                    │               │
│         │                │ native             │ plugin        │
│         │                ▼                    ▼               │
│         │         HTTP + Parser         site HTTP/API/HTML    │
│         │                │                    │               │
│         └────────────────┴──────────┬─────────┘               │
│                                     ▼                         │
│                         normalized entries                    │
│                         Feeds.upsert_entries/2                │
│                         scheduler meta update                 │
└──────────────────────────────────────────────────────────────┘
```

**Native adapter** wraps today’s `HTTP.get` + `Parser.parse` path.  
**Plugin adapters** replace only the fetch/parse step; storage and multi-user state stay in core.

---

## 4. Contract (`earss_source`)

Module names below are normative for the contract package. Earss may re-export or alias them.

### 4.1 Adapter behaviour

```elixir
defmodule Earss.Source.Adapter do
  @moduledoc """
  Implemented by the built-in native feed adapter and by external plugins.
  """

  @type entry :: %{
          required(:link) => String.t(),
          required(:guid) => String.t(),
          optional(:title) => String.t() | nil,
          optional(:author) => String.t() | nil,
          optional(:summary) => String.t() | nil,
          optional(:content) => String.t() | nil,
          optional(:published_at) => DateTime.t() | nil
        }

  @type feed_meta :: %{
          optional(:title) => String.t() | nil,
          optional(:description) => String.t() | nil,
          optional(:site_url) => String.t() | nil
        }

  @type fetch_ok :: %{
          optional(:feed) => feed_meta(),
          required(:entries) => [entry()],
          optional(:etag) => String.t() | nil,
          optional(:last_modified) => String.t() | nil,
          optional(:content_hash) => String.t() | nil,
          optional(:cursor) => map()
        }

  @type route_spec :: %{
          required(:path) => String.t(),
          required(:description) => String.t(),
          optional(:params) => [map()],
          optional(:example) => String.t()
        }

  @type resolve_ok :: %{
          required(:source_url) => String.t(),
          optional(:title) => String.t() | nil,
          optional(:meta) => map(),
          optional(:min_refresh_interval) => pos_integer(),
          optional(:max_refresh_interval) => pos_integer(),
          optional(:default_refresh_interval) => pos_integer()
        }

  @callback id() :: String.t()
  @callback adapter_api() :: pos_integer()
  @callback routes() :: [route_spec()]

  @callback resolve(input :: String.t() | map()) ::
              {:ok, resolve_ok()} | {:error, term()}

  @callback fetch(feed :: struct(), opts :: keyword()) ::
              {:ok, fetch_ok()}
              | {:ok, :not_modified}
              | {:error, term()}
end
```

Notes:

- **`adapter_api/0`**: integer version of this behaviour (start at **1**). Core refuses adapters with unsupported API major.
- **`entry`** shape **matches** what `Earss.Feeds.Parser` already produces so `upsert_entries/2` stays unchanged (guid normalization, content_hash, D4).
- **`cursor`**: opaque JSON map stored on the feed for the next poll (pagination tokens, last remote id). Core does not interpret keys.
- **`fetch` opts** (core → adapter): at least `:force` (boolean, skip conditional short-circuit), and may pass previous etag/last_modified/hash/cursor from the feed struct.
- Adapters **must not** write to the database. Return data only; core persists.

### 4.2 Entry rules (same as core feeds)

1. `guid` and `link` required after normalization; empty guid may fall back to link (core upsert already does this).
2. Timestamps: `DateTime` UTC, second precision preferred.
3. HTML in `content`/`summary` is stored as provided; display sanitization is a separate hardening concern.
4. Same `(feed_id, guid)` updates mutable fields without resetting user `entry_states` (D4).

### 4.3 Registry (implemented in **earss**, used by plugins)

```elixir
# Pseudocode — API shape for docs
Earss.Source.Registry.register(%{
  id: "example",
  module: MyApp.Source.Example,
  # optional metadata
  version: "0.1.0"
})

Earss.Source.Registry.fetch("example")
# => {:ok, MyApp.Source.Example}

Earss.Source.Registry.list_adapters()
Earss.Source.Registry.list_routes()
```

Registration is expected in the plugin application’s `start/2` (or a child that runs once). Duplicate `id` → log error and keep the first (or last—implementation must pick one and document it; prefer **reject duplicate**).

### 4.4 Resolution algorithm (core)

Given subscription input `link` (string):

1. Trim.
2. If scheme is `http` or `https` → **native** adapter; `source_url = link`.
3. If scheme is `earss` → parse `adapter_id` from host/path form of URI; look up Registry; call `adapter.resolve(link)`.
4. Else → `{:error, :unsupported_scheme}`.

Recommended URI form for R1:

```
earss://bilibili/user/123
```

Parsing note: Elixir `URI` treats `bilibili` as **host** and `/user/123` as **path**. Document this as the canonical form. Adapters should accept this form in `resolve/1`.

### 4.5 Fetch dispatch (core Fetcher)

1. Load feed.
2. Determine adapter: `feed.adapter_id` if set, else resolve from `feed.link`, else native.
3. Call `adapter.fetch(feed, opts)`.
4. On `{:ok, :not_modified}` → existing not-modified / interval lengthening path.
5. On `{:ok, payload}` → merge feed meta, persist cursor/etag/hash, `upsert_entries`, scheduler adaptation (D1).
6. On `{:error, reason}` → `error_count`, `last_error`, backoff; never crash the poller batch.

Plugin exceptions: rescue/catch in core, convert to `{:error, {:adapter, id, exception}}`.

---

## 5. Data model (planned, additive)

Milestone name (when implemented): e.g. **`db-schema-v1.1-sources`** or a v2 slice—**additive only** if production data exists.

| Column | Type | Notes |
|--------|------|--------|
| `adapter_id` | `text` null | `"native"` may be stored or null meaning native; plugins store their `id/0` |
| `source_kind` | `string` | `"native"` \| `"plugin"` (denormalized convenience for queries/UI) |
| `adapter_cursor` | `map` / jsonb null | Last successful `fetch_ok.cursor` |
| `adapter_config` | `map` / jsonb null | Non-secret per-feed options (filters). Prefer empty at first. |

`feed_type` CHECK expansion:

- Keep `rss` \| `atom` \| `json` for native.
- Add **`plugin`** for adapter-backed rows (content is not a feed document type).

Indexes:

- Optional `(source_kind, adapter_id)` for Admin filters.
- Unique `link` unchanged.

Secrets (API keys, cookies):

- **Not** in `adapter_config` for v1.
- Use plugin application env / `config/runtime.exs` of the **deploying** release.

---

## 6. Product surfaces

### 6.1 Subscribe

| Input | Path |
|-------|------|
| `https://…/feed.xml` | Native `ensure_feed` |
| `earss://adapter/…` | `resolve` → `ensure_feed` with `adapter_id` / `source_kind` |
| Admin plugin form | Build `earss://…` from route + params, then same as above |

`Reader.subscribe/2` stays the user-facing API; it should pass through link + optional adapter attrs to `Feeds.ensure_feed/2`.

### 6.2 Clients (Fever / GReader / JSON API)

No protocol changes required: they address feeds/entries by **numeric ids** and read stored content.

### 6.3 OPML

- Export may emit `xmlUrl` = `earss://…` for plugin feeds.
- Re-import works only on instances that have the same adapter installed.
- Document that third-party readers will not understand `earss://` URLs.

### 6.4 Admin (later phase)

- List registered adapters + versions.
- Route catalog from `routes/0`.
- Subscribe wizard (params → URL).
- Feed detail: adapter id, last error, non-sensitive cursor summary.

---

## 7. Plugin package conventions

### 7.1 Layout

```
earss_source_example/
  mix.exs                 # {:earss_source, "~> 0.1"}
  lib/earss_source_example/application.ex
  lib/earss_source_example/adapter.ex
  test/
  README.md               # routes table, config, legal notes
```

### 7.2 Application start

```elixir
def start(_type, _args) do
  :ok =
    Earss.Source.Registry.register(%{
      id: EarssSourceExample.Adapter.id(),
      module: EarssSourceExample.Adapter,
      version: Application.spec(:earss_source_example, :vsn) |> to_string()
    })

  # children if any
  Supervisor.start_link([], strategy: :one_for_one)
end
```

**Ordering:** the plugin application must start **after** the registry is available. Prefer:

- Registry in a core app that starts first, or
- Registry as a bare ETS owned by `:earss` with plugins started after `:earss` in the release.

Document the exact supervision rule in the implementation PR.

### 7.3 Deploy (operator)

Earss core does **not** list site plugins as hard dependencies. Operators add them in **their** release/umbrella/`mix.exs`:

```elixir
defp deps do
  [
    {:earss, "..."},
    {:earss_source, "~> 0.1"},
    {:earss_source_example, github: "you/earss_source_example", tag: "v0.1.0"}
  ]
end
```

### 7.4 Testing plugins

Contract package should offer helpers (phase S):

- Assert `fetch_ok` map shape.
- Assert entries pass the same guid/link rules as core upserts.
- Optional ExUnit case template with a fake feed struct.

Plugins should **not** require a live PostgreSQL Earss instance for pure `resolve/1` + pure `fetch/2` tests (use Bypass/Req stubs).

### 7.5 Minimal example (illustrative)

```elixir
defmodule EarssSourceExample.Adapter do
  @behaviour Earss.Source.Adapter

  @impl true
  def id, do: "example"

  @impl true
  def adapter_api, do: 1

  @impl true
  def routes do
    [
      %{
        path: "hello/:name",
        description: "Demo route",
        example: "earss://example/hello/world"
      }
    ]
  end

  @impl true
  def resolve("earss://example/hello/" <> name) do
    name = String.trim(name)

    {:ok,
     %{
       source_url: "earss://example/hello/#{name}",
       title: "Hello #{name}",
       meta: %{name: name}
     }}
  end

  def resolve(_), do: {:error, :unknown_route}

  @impl true
  def fetch(feed, _opts) do
    name = feed.link |> URI.parse() |> Map.get(:path) |> to_string() |> Path.basename()
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    guid = "example-#{name}-#{Date.to_iso8601(DateTime.to_date(now))}"

    {:ok,
     %{
       feed: %{title: "Hello #{name}", site_url: "https://example.com"},
       entries: [
         %{
           guid: guid,
           link: "https://example.com/hello/#{name}",
           title: "Daily hello for #{name}",
           content: "<p>hi</p>",
           published_at: now
         }
       ],
       content_hash: guid
     }}
  end
end
```

---

## 8. Security & abuse

1. **Plugins are trusted code**, same as any Mix dependency.
2. Core never evaluates remote source at runtime.
3. Adapters must not receive user password hashes or session cookies from Earss.
4. Rate limiting: plugins should use polite intervals; core may later wrap shared HTTP with per-host caps (Phase 7).
5. Legal/ToS compliance for scraping is the **plugin author / operator** responsibility.
6. Do not store secrets in `adapter_cursor` or `adapter_config` without encryption design (out of scope for v1).

---

## 9. Relation to RSSHub

| RSSHub | Earss plugins |
|--------|----------------|
| Node service exposing many HTTP routes as RSS | Elixir OTP apps registered into Earss |
| Central catalog in one project | Decentralized packages you maintain |
| Always HTTP RSS output | Normalized entries in-process |
| Path culture `/site/type/id` | Similar UX via `earss://adapter/...`, different runtime |

If RSSHub already solves a site for you, subscribe with the **native** HTTPS feed URL. Plugins are for custom, private, or in-process integrations without running another service.

---

## 10. Implementation phases (summary)

Detailed checkboxes live in [roadmap.md](roadmap.md) under **Phase S**.

| Phase | Outcome |
|-------|---------|
| **S0** | This design doc + contract draft (done when `docs/sources.md` is merged) |
| **S1** | Create `earss_source` package (behaviour + types); Earss depends on it |
| **S2** | Registry + native adapter; Fetcher dispatches without behaviour change |
| **S3** | DB columns + `earss://` resolve on subscribe |
| **S4** | Example plugin package (separate repo) end-to-end |
| **S5** | Admin routes UI + system plugin list |
| **S6** | Politeness helpers, API versioning polish, docs for authors |

---

## 11. Open items (implementation-time)

Not blockers for the design freeze, but must be decided in the S1/S2 PR:

- Exact URI parsing edge cases (`earss:example/...` without `//` — reject vs accept).
- Whether `adapter_id` null or `"native"` is stored for classic feeds.
- Registry ownership (ETS table name, app start order in releases).
- Hex publish vs monorepo path for `earss_source` initially.

---

## 12. Versioning

| Artifact | Versioning |
|----------|------------|
| This doc | Update when R1/C2 or behaviour callbacks change |
| `earss_source` | Semver; **breaking** callback changes bump major / `adapter_api` |
| Plugins | Own versions; declare supported `adapter_api` and `earss_source` requirement |

**Design freeze tag (docs only):** `sources-design-r1-c2` (optional git tag when operators want a doc pin).
