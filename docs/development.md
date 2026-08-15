# Development guide

> 📖 End-user flows (credentials, subscribing, readers): [User guide](usage.md).

## Prerequisites

- Elixir **1.18+** and a matching OTP
- PostgreSQL (local or container)
- Ability to run `CREATE EXTENSION citext`

## First-time setup

```bash
git clone <repo-url> earss
cd earss
mix setup
```

`mix setup` runs `deps.get`, `ecto.create`, and `ecto.migrate` against the **dev** database.

### Database settings

| Env | File | Default database |
|-----|------|------------------|
| dev | `config/dev.exs` | `earss_dev` |
| test | `config/test.exs` | `earss_test` (SQL Sandbox) |
| prod | `config/runtime.exs` | **`DATABASE_URL` required** |

Default dev credentials assume local trust/peer or empty password for role `postgres`. Edit `config/dev.exs` / `config/test.exs` if your cluster differs.

### Operator env (`earss.env`)

Copy the template and set only what you need:

```bash
cp earss.env.example earss.env
```

| Consumer | When | Keys |
|----------|------|------|
| `mix.exs` | `deps.get` / compile | `EARSS_SOURCE_PLUGINS` |
| `config/runtime.exs` | every boot **except** `MIX_ENV=test` | DB, API, poller, host politeness, retention, refresh, HTTP client, … |

Shell / CI / Docker env always wins over file values.  
`/admin/system` reads the same `Application` config after runtime merge — no separate Admin store.  
Full key list: [`earss.env.example`](../earss.env.example).

Production deploy (release, systemd): [deploy.md](deploy.md).  
NixOS flake module: [nixos.md](nixos.md).  
Production data protection: [backup.md](backup.md) (PostgreSQL dump/restore, secrets, plugins).

### Useful aliases

| Alias | Action |
|-------|--------|
| `mix setup` | Install deps + create + migrate |
| `mix ecto.setup` | Create + migrate |
| `mix ecto.reset` | Drop + setup |
| `mix test` | Quiet create/migrate test DB, then run tests |

## Running tests

```bash
mix test
```

Contract tests live in `test/earss/schema_contract_test.exs` and cover:

- Uniqueness (feed link, entry guid, username citext, subscription, category)
- Cascades and category nilify
- `entry_states` read_at consistency
- Long URL (`text`) acceptance

`Earss.DataCase` (`test/support/data_case.ex`) starts a Sandbox owner per test.

Argon2 is configured with low costs in `config/test.exs` for speed.

## Project conventions

### Contexts

- Put multi-schema workflows in `Earss.Feeds` or `Earss.Reader`, not in schema modules.
- Schema modules own `changeset/2` validation only.
- Prefer returning `{:ok, struct} | {:error, changeset | atom}` from public context functions.

### Module boundaries

Call sites should keep using the stable facades (`Earss.Reader`, `Earss.GReader`, `Earss.Admin.Router`). Internal splits:

| Facade | Implementation modules |
|--------|------------------------|
| `Earss.Reader` | `Users`, `Categories`, `Subscriptions`, `EntryStates`, `Timeline`, `OPMLImport` under `lib/earss/reader/`; Fever listings in `Earss.Fever.Queries` |
| `Earss.GReader` | `Auth`, `Ids`, `Streams`, `Items`, `Subscriptions`, `Format` under `lib/earss/greader/` |
| `Earss.Admin.Router` | Thin route table; `Controllers/*` + `Views/*` + `Helpers` / `ControllerHelpers` |

Rules:

- **Schemas** (`Reader.User`, …): changesets and associations only.
- **Reader submodules**: domain use cases and lifecycle side effects; no HTTP or protocol IDs.
- **Fever / GReader**: protocol mapping and response shapes; prefer calling Reader instead of re-implementing state writes.
- **Admin Controllers**: params, authz, context calls, redirects; no large HTML blobs.
- **Admin Views / HTML**: rendering only; no `Repo` access.
- Prefer `defdelegate` on facades when moving code so existing tests and clients keep compiling.

### Source plugins

Site-specific non-RSS ingestion is **out of core**. See [sources.md](sources.md):

- Canonical plugin URLs: `earss://<adapter_id>/…` (**R1**)
- Plugins depend on package **`earss_source`** (**C2**) for the behaviour; at runtime they register on `Earss.Source.Registry`
- Core always ships native RSS/Atom/JSON; plugins are optional deps

Enable optional source plugins via env (auto-loaded from `earss.env`).
You pass full Mix dep specs — the host does not maintain a plugin allow-list:

```bash
cp earss.env.example earss.env
# EARSS_SOURCE_PLUGINS=github:ll1zt/earss_source_telegram@main
mix deps.get && mix compile
iex -S mix
```

One-shot: `EARSS_SOURCE_PLUGINS=github:org/earss_source_foo@main mix deps.get`.  
See `earss.env.example` for `github:` / `git:` / `hex:` / `path:` grammar.

### Time

- Persist UTC with `utc_datetime` (second precision is fine for app-level stamps).
- When setting `DateTime.utc_now()`, truncate to seconds before insert if required by the column type.

### Passwords

- Hash in the Reader context (Argon2), never store plaintext.
- Use `Argon2.no_user_verify/0` on missing users to reduce timing leaks.

### Migrations

- For published/production history, prefer additive migrations.
- `db-schema-v1` rewrote the initial migration set while the project had no production data—do not rewrite applied production migrations later.

### Documentation

- English is the language for project docs under `docs/` and `README.md`.
- Schema changes require updates to `data_model.md` and, if behavior changes, `data_lifecycle.md`.

## HTTP API

With `config :earss, :api, enabled: true` (default in dev), Bandit serves
`Earss.API.Router` on port **4000**. See [api.md](api.md), [fever.md](fever.md),
and [greader.md](greader.md).

| URL | Purpose |
|-----|---------|
| `http://localhost:4000/admin` | Web admin |
| `http://localhost:4000/api/auth/login` | JSON API Bearer login |
| `http://localhost:4000/fever/` | Fever (NNW account type Fever) |
| `http://localhost:4000/api/greader.php` | FreshRSS / GReader (NNW account type FreshRSS) |

```bash
# after mix setup and creating a user in iex:
curl -s -X POST http://localhost:4000/api/auth/login \
  -H 'content-type: application/json' \
  -d '{"username":"admin","password":"secret"}'

# GReader ClientLogin
curl -s -X POST http://localhost:4000/api/greader.php/accounts/ClientLogin \
  -H 'content-type: application/x-www-form-urlencoded' \
  -d 'Email=admin&Passwd=secret'
```

Focused test suites:

```bash
mix test test/earss/api_test.exs
mix test test/earss/fever_test.exs
mix test test/earss/greader_test.exs
mix test test/earss/admin_test.exs
```

## Interactive console

```bash
iex -S mix
```

Examples:

```elixir
alias Earss.Reader
alias Earss.Feeds

# single-operator mode: credentials come from ADMIN_PASSWORD (earss.env)
Reader.authenticate_user("admin", "secret")

# Subscribe (ensures feed, queues fetch, optional immediate refresh)
{:ok, sub} =
  Reader.subscribe(user, %{
    link: "https://www.ietf.org/blog/feed.xml",
    title: "IETF",
    refresh: true
  })

Reader.list_entries(user)
Reader.list_entries(user, unread_only: true)

entry_id = hd(Reader.list_entries(user)).entry.id
Reader.mark_read(user, entry_id)
Reader.set_star(user, entry_id, true)

{:ok, cat} = Reader.create_category(user, %{name: "Blogs"})
Reader.update_subscription(sub, %{category_id: cat.id})
```

### Scheduler / poller

- `Earss.FeedScheduler` — interval math + `list_due_feeds/1`
- `Earss.FeedPoller` — supervised when `config :earss, :poller, enabled: true` (off in test)
- Due feeds require at least one **subscription** (`Reader.subscribe/2`)
- `FeedScheduler.initialize_next_fetch(feed)` sets `next_fetch_at` to now

```elixir
config :earss, :poller,
  enabled: true,
  interval_ms: 5 * 60 * 1000,
  batch_size: 50,
  max_concurrency: 5
```

### Retention

- `Earss.Retention.run_all/0` — Level A (states) → B (entries) → C (orphan feeds)
- `dry_run: true` counts without deleting
- `Earss.RetentionPoller` — daily by default (off in test)

```elixir
Earss.Retention.run_all(dry_run: true)
Earss.Retention.run_all()

config :earss, :retention,
  read_state_days: 90,
  entry_days: 180,
  unsubscribed_feed_days: 30
```

### HTTP client in tests

Tests stub HTTP via:

```elixir
Application.put_env(:earss, :http_client, Earss.Feeds.HTTPStub)
Earss.Feeds.HTTPStub.put(fn _url, _opts ->
  {:ok, %{status: 200, body: File.read!("test/fixtures/feeds/sample.rss.xml"), etag: nil, last_modified: nil}}
end)
```

## Formatting

```bash
mix format
```

## Troubleshooting

| Symptom | Likely cause |
|---------|----------------|
| `citext` errors on migrate | Role lacks permission for `CREATE EXTENSION` |
| Sandbox / checkout errors in tests | Missing `DataCase` / Sandbox mode in `test_helper.exs` |
| `rebar3` / telemetry compile prompts | Run `mix local.rebar --force` once |
| Auth always unauthorized | User `is_active = false` or wrong password hash path |

## Related docs

- [Architecture](architecture.md)
- [Data model](data_model.md)
- [Roadmap](roadmap.md)
