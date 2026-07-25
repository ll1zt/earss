# earss_source

Stable **source adapter contract** for [Earss](https://github.com/ll1zt/earss) plugins (design **C2**).

Plugin packages should depend on this library **only** (not on private `Earss.*` modules), implement `Earss.Source.Adapter`, and register with the host at runtime.

Canonical plugin URLs use the `earss://` scheme (**R1**). Full design: `docs/sources.md` in the Earss repository.

## Adapter API

Current version: **1** (`Earss.Source.Adapter.api_version/0`).

## Use as a path dependency (development)

```elixir
{:earss_source, path: "packages/earss_source"}
```

## License

Same as Earss (see repository root `LICENSE`).
