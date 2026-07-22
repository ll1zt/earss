# Development guide

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
| prod | `config/runtime.exs` | `DATABASE_URL` |

Default dev credentials assume local trust/peer or empty password for role `postgres`. Edit `config/dev.exs` / `config/test.exs` if your cluster differs.

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

## Interactive console

```bash
iex -S mix
```

Examples:

```elixir
alias Earss.Reader
alias Earss.Feeds

{:ok, user} = Reader.create_user("admin", "secret")
Reader.authenticate_user("admin", "secret")

{:ok, feed} = Feeds.create_feed(%{link: "https://example.com/feed.xml", title: "Example"})
{:ok, ^feed} = Feeds.ensure_feed("https://example.com/feed.xml")

{:ok, _entry} =
  Feeds.upsert_entry(feed, %{
    link: "https://example.com/post-1",
    guid: "post-1",
    title: "Hello"
  })

# Same guid updates mutable fields (D4)
{:ok, _} =
  Feeds.upsert_entry(feed, %{
    link: "https://example.com/post-1",
    guid: "post-1",
    title: "Hello (updated)"
  })

Feeds.list_entries(feed)

# Phase 2: single refresh cycle (live network)
{:ok, feed} = Feeds.ensure_feed("https://www.ietf.org/blog/feed.xml", %{title: "IETF"})
Feeds.refresh(feed)
# => {:ok, %{upserted: n, skipped: 0, feed: %Feed{...}}}
# or {:ok, :not_modified} / {:error, {:http | :parse, reason}}
```

### Scheduler / poller

- `Earss.FeedScheduler` — interval math + `list_due_feeds/1`
- `Earss.FeedPoller` — supervised when `config :earss, :poller, enabled: true` (off in test)
- Due feeds require at least one **subscription** row; until Phase 4, create one via Repo or call `Feeds.refresh/1` manually
- `FeedScheduler.initialize_next_fetch(feed)` sets `next_fetch_at` to now

```elixir
config :earss, :poller,
  enabled: true,
  interval_ms: 5 * 60 * 1000,
  batch_size: 50,
  max_concurrency: 5
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
