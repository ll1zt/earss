# earss_source

Stable **source adapter contract** for [Earss](https://github.com/ll1zt/earss) plugins (design **C2**).

Plugin packages should depend on this library **only** (not on private `Earss.*` modules), implement `Earss.Source.Adapter`, and register with the host at runtime.

Canonical plugin URLs use the `earss://` scheme (**R1**). Full design: `docs/sources.md` in the Earss repository.

## Adapter API

Current version: **1** (`Earss.Source.Adapter.api_version/0`).

Callbacks: `id/0`, `adapter_api/0`, `routes/0`, `resolve/1`, `fetch/2`.

- **`resolve/1`** — validate route, return stable `source_url` (+ optional refresh intervals).
- **`fetch/2`** — one poll cycle; **no DB writes**. Return entries matching the contract shape.

## Politeness helpers

`Earss.Source.Politeness` (pure, no I/O):

| Function | Use |
|----------|-----|
| `default_plugin_intervals/0` | Suggested min/default/max minutes for scrapers |
| `clamp_interval/4` | Clamp operator/custom intervals |
| `host_key/1` | Host for Earss `HostLimiter` / rate limits (use the **remote** URL you HTTP to) |
| `retry_after_seconds/1` | Parse `Retry-After` from response headers |

Example in `resolve/1`:

```elixir
intervals = Earss.Source.Politeness.default_plugin_intervals()

{:ok,
 Map.merge(
   %{
     source_url: "earss://example/hello/world",
     title: "Hello"
   },
   intervals
 )}
```

## OPML

- Host export writes `xmlUrl` = `feeds.link` (`https://…` or `earss://…`).
- Plugin rows use `type="earss"` on export; HTTP feeds keep `type="rss"`.
- Import uses `xmlUrl` as subscribe `link` — **the target Earss must have the same plugin installed** or subscribe fails for unknown adapters.
- Keep `source_url` stable across plugin versions so OPML round-trips remain valid.

## Use as a path dependency (development)

```elixir
{:earss_source, path: "packages/earss_source"}
# or path/git dep from an Earss host monorepo
```

## Host enablement

Operators install plugins via the Earss host env, e.g.:

```bash
EARSS_SOURCE_PLUGINS=github:you/earss_source_example@main
```

See Earss `earss.env.example` and `docs/sources.md`.

## License

Same as Earss (see repository root `LICENSE`).
