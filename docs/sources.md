# Source adapters & plugins

> 📖 Subscribing via the Sources wizard: [User guide → Plugin sources](usage.md).

**Status:** design + **S1–S6** (contract, registry, schema, Telegram reference, Admin sources, politeness/author/OPML notes).  
Reference plugin: [`ll1zt/earss_source_telegram`](https://github.com/ll1zt/earss_source_telegram).  
**Decisions locked:** **R1** (`earss://` URLs) · **C2** (separate `earss_source` contract package)

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

## 5. Data model (implemented, additive)

Migration: `priv/repo/migrations/20260725091358_add_source_adapter_fields_to_feeds.exs`.  
Also summarized in [data_model.md](data_model.md) (additive source-adapter fields).

| Column | Type | Notes |
|--------|------|--------|
| `adapter_id` | `text` | Default `"native"` for classic feeds; plugins store their `id/0` |
| `source_kind` | `string` | `"native"` \| `"plugin"` |
| `adapter_cursor` | `map` null | Last successful `fetch_ok.cursor` |
| `adapter_config` | `map` null | Non-secret per-feed options (optional; often empty) |

`feed_type` CHECK:

- Native: `rss` \| `atom` \| `json`
- Plugin rows: **`plugin`**

Indexes: `(source_kind, adapter_id)` plus existing `unique(link)`.

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

### 6.4 Admin

**Admin (S5):** `/admin/sources` — registered adapters, plugin route forms (path params → `earss://…`), free-form URL subscribe. Subscription detail shows `source_kind` / `adapter_id` / cursor. HTTPS feeds still use **Subscriptions**.

### 6.5 Registration / start order

- `Earss.Source.Registry` starts inside **`:earss`**.
- Optional plugin apps may start **before** `:earss` when added as Mix deps. Their first `register/1` can fail; this is expected.
- Host `Earss.Application` registers **native**, then any **loaded** reference adapter modules (e.g. `EarssSourceTelegram.Adapter` when the package is on the code path).
- Plugins may also **retry** registration briefly after boot (see `earss_source_telegram`).

If `list_adapters/0` lacks your plugin, call `Earss.Source.Registry.register/1` once in IEx or fix start order / deps enablement.

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

Earss core does **not** hard-depend on site plugins. Stock `mix test` / default `mix.exs` stay plugin-free.

#### Optional plugins via env (this repo)

Operators choose **what to install** freely via env (or `earss.env`, auto-loaded by `mix.exs`). There is **no host allow-list / id catalog** — each entry is a Mix dependency spec. Trust and supply-chain review are on the operator.

```bash
cp earss.env.example earss.env
# EARSS_SOURCE_PLUGINS=github:ll1zt/earss_source_telegram@main
# # multiple:
# # EARSS_SOURCE_PLUGINS=github:ll1zt/earss_source_telegram@main,path:../my_plugin
mix deps.get && mix compile
iex -S mix

# One-shot / deploy without a file:
EARSS_SOURCE_PLUGINS=github:ll1zt/earss_source_telegram@main mix deps.get
```

Spec grammar (comma-separated):

| Form | Example |
|------|---------|
| `github:owner/repo[@ref]` | `github:ll1zt/earss_source_telegram@main` |
| `git:url[@ref]` | `git:https://git.example/p.git@v1.0.0` |
| `hex:name[@req]` | `hex:earss_source_foo@~>0.1` |
| `path:dir` | `path:../earss_source_telegram` |
| `app\|…` | override OTP app name: `my_app\|github:org/repo@main` |

`@ref`: omitted/`main` → branch; `v1.2.3` or `1.2.3` → tag; 7–40 hex → git ref.

At runtime, adapters register if the plugin app starts after the Registry, or via discovery: loaded apps named `earss_source_*` → module `EarssSource*.Adapter`. Override with `EARSS_SOURCE_ADAPTERS=Some.Adapter,Other.Adapter`.

Subscribe after start:

```elixir
Earss.Source.Registry.list_adapters()
# should include id: "telegram" when the plugin app started

# single-operator mode: credentials come from ADMIN_PASSWORD (earss.env)
{:ok, _} =
  Earss.Reader.subscribe(u, %{
    link: "earss://telegram/channel/journey_of_someone",
    refresh: true
  })
```

#### Manual / release `mix.exs`

```elixir
defp deps do
  [
    {:earss, "..."},
    # contract is already a path/git dep of earss; plugins need it only for compiling the plugin itself
    {:earss_source_telegram, github: "ll1zt/earss_source_telegram", branch: "main"}
    # prefer tag once you pin releases: tag: "v0.1.0"
  ]
end
```

**Start order:** `:earss` (registry) must start before the plugin application registers. With a normal Mix dependency graph this is automatic when the plugin app’s `Application.start/2` calls `Earss.Source.Registry.register/1`.

#### Reference plugin

| Package | Repo | Route |
|---------|------|--------|
| `earss_source_telegram` | https://github.com/ll1zt/earss_source_telegram | `earss://telegram/channel/<username>` |

Fetches public previews at `https://t.me/s/<username>` (no Bot token). See that repo’s README for limits (one preview page, markup drift, ToS).

### 7.3.1 Smoke test (Telegram)

```bash
cd /path/to/earss
cp earss.env.example earss.env   # EARSS_SOURCE_PLUGINS=github:ll1zt/earss_source_telegram@main
mix deps.get
mix ecto.migrate
iex -S mix
```

```elixir
Earss.Source.Registry.list_adapters() |> Enum.map(& &1.id)
# => ["native", "telegram"] (order may vary)

# single-operator mode: credentials come from ADMIN_PASSWORD (earss.env)
# or: u = Earss.Reader.get_user_by_username("tg_test")

{:ok, sub} =
  Earss.Reader.subscribe(u, %{
    link: "earss://telegram/channel/journey_of_someone",
    refresh: true
  })

feed = sub.feed
# If refresh failed or timed out:
# Earss.Feeds.refresh(feed, force: true)

Earss.Feeds.list_entries(feed) |> Enum.map(& &1.title) |> Enum.take(5)
```

Then optionally open Admin / Fever / GReader with the same user. Manual refresh is recommended for smoke tests; poller uses the adapter’s longer default interval (often 60–120 minutes).

### 7.4 Testing plugins

- Host tests cover registry + stub adapters (`test/earss/source/*`).
- Contract package ships pure helpers (`Earss.Source.Politeness`); assert `fetch_ok` shape in the plugin’s own suite.
- Plugins should **not** require a live PostgreSQL Earss instance for pure `resolve/1` + pure `fetch/2` tests (use Bypass/Req stubs).

### 7.4.1 Author guide (checklist)

1. **Depend only on `:earss_source`** — never on private `Earss.Feeds` / `Earss.Repo`.
2. Implement `Earss.Source.Adapter` with `adapter_api/0 == 1`.
3. **Stable `source_url`** — `earss://<id>/…` identity must not change when scrape code changes (OPML + multi-user subs).
4. **Intervals** — for remote scrapes, merge `Earss.Source.Politeness.default_plugin_intervals/0` into `resolve/1` (or stricter).
5. **HTTP** — use your own client (e.g. Req); on 429/503 read `Retry-After` via `Politeness.retry_after_seconds/1` and return `{:error, …}` or back off; set a clear User-Agent.
6. **Host key** — when limiting by remote host, call `Politeness.host_key(remote_url)` (not the `earss://` link).
7. **Register** — plugin `Application` registers on `Earss.Source.Registry`, **or** name the OTP app `earss_source_*` and export `EarssSource*.Adapter` for host auto-discovery.
8. **No DB** — `fetch/2` returns data only; host upserts entries.
9. **Secrets** — do not put tokens in `adapter_cursor` / `adapter_config` without an encryption story.
10. **OPML** — document required host plugins; export uses `xmlUrl=source_url` and `type="earss"` for plugin rows.

### 7.4.2 OPML and plugin sources

| Direction | Behaviour |
|-----------|-----------|
| **Export** | `xmlUrl` = `feeds.link` (`https://…` or `earss://…`). HTTP feeds: `type="rss"`. Plugin feeds: `type="earss"`. |
| **Import** | Outline folders → categories; each outline with `xmlUrl` → `Reader.subscribe(link: xmlUrl)`. Import does **not** require `type="earss"`; any `xmlUrl` is tried. |
| **Interop** | Standard readers may ignore or mishandle `earss://` URLs. Treat OPML with plugins as **Earss-to-Earss** (or document which plugins the destination must install). |
| **Missing plugin** | Subscribe returns an adapter/resolve error; import counts it under `errors` / skipped paths depending on error shape. |

Round-trip is stable only if the destination has the **same adapter_id packages** enabled (`EARSS_SOURCE_PLUGINS` / release deps).

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
4. Rate limiting: use `Earss.Source.Politeness` for intervals / Retry-After; core may later wrap shared HTTP with per-host caps (Phase 7).
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

| Phase | Outcome | Status |
|-------|---------|--------|
| **S0** | Design doc (`docs/sources.md`) | Done |
| **S1** | `packages/earss_source` contract (`adapter_api` = 1) | Done |
| **S2** | Registry + native adapter; Fetcher dispatch | Done |
| **S3** | DB columns + `earss://` ensure/subscribe | Done |
| **S4** | Reference plugin `earss_source_telegram` + optional host wiring | Done |
| **S5** | Admin `/admin/sources` adapters + route wizard | Done |
| **S6** | Politeness helpers, author guide, OPML notes | Done |

---

## 11. Open items

Mostly closed for S1–S6; remaining optional / later:

- URI edge cases (`earss:example/...` without `//` — currently reject / treat carefully).
- Publishing `earss_source` as its own Hex package (optional; monorepo path + git sparse still fine).
- Shared **enforced** per-host crawl caps inside core HTTP (Phase 7); S6 only provides pure helpers for adapters.

---

## 12. Versioning

| Artifact | Versioning |
|----------|------------|
| This doc | Update when R1/C2 or behaviour callbacks change |
| `earss_source` | Semver; **breaking** callback changes bump major / `adapter_api` |
| Plugins | Own versions; declare supported `adapter_api` and `earss_source` requirement |

**Design freeze tag (docs only):** `sources-design-r1-c2` (optional git tag when operators want a doc pin).
