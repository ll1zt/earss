# TTS / listen-later pipeline

Turn articles into audio: a "🎧 Listen" control injected into article content
captures the intent, a background worker synthesizes audio via a provider
plugin, and an **Apple-Podcasts-compatible feed** serves the results.

## Pieces

| Piece | Module | Role |
|-------|--------|------|
| Listen control | `Earss.API.ListenControls` | Renders the "🎧 Listen" anchor into entry content at protocol-render time (GReader, Fever, JSON API). Never stored. |
| Listen endpoint | `Earss.API.Listen` | `GET /tts/listen/:entry_id?sig=…` records the intent. Unauthenticated: the signed link stands in for the reader session. |
| Signed links | `Earss.TTS.Link` | `Plug.Crypto` HMAC (`SECRET_KEY_BASE`, salt `earss.tts.listen`). Signatures never expire (single operator). |
| Request rows | `Earss.TTS.Request` / `Earss.TTS` | One row per entry: `requested → processing → ready | failed`, with `retry_at` backoff and `attempt_count`. |
| Worker | `Earss.TTS.Worker` | Tick loop: requeue lease-expired rows, claim due rows, synthesize (sync ≤ `max_chars_sync` chars, else async submit/poll/download), write `<audio_dir>/<entry_id>.<ext>`, mark `ready`. |
| Provider contract | `packages/earss_tts` (`Earss.TTS.Provider`) | Plugin API (version 1): required `synthesize/2`, optional `submit/2` + `poll/2` + `download/2`. |
| Podcast feed | `Earss.TTS.Podcast` | `GET /podcast/rss.xml` + byte-range media endpoints (Apple Podcasts / AVPlayer compatible: HEAD, `Range`, 206, `Content-Range`). |

## Enabling

```bash
# earss.env — intent capture (injects the control into article content)
EARSS_TTS_LISTEN_CONTROLS=true
# Absolute base for injected links + feed enclosure URLs. With the feed the
# configured public_url should ALWAYS be set: podcast clients fetch media
# from URLs embedded in the feed, so the base must be reachable from the
# player, not just from the reader client.
EARSS_TTS_PUBLIC_URL=https://earss.example.net

# Synthesis (both keys required; without them the worker never mounts)
EARSS_TTS_WORKER_ENABLED=true
EARSS_TTS_AUDIO_DIR=/var/lib/earss/audio

# Provider plugin (compile-time dep, like source plugins)
EARSS_TTS_PLUGINS=path:../earss_tts_podcast
```

Reference provider: [`earss_tts_podcast`](https://github.com/ll1zt/earss_tts_podcast)
(Fish Audio; configures itself via `EARSS_TTS_PODCAST_*` env).

### HTTPS requirement (Apple Podcasts)

Apple Podcasts will silently fail (endless loading) on plain-HTTP episode
media. Serve the feed over TLS — the cheapest option on a tailnet is
`tailscale serve`, which provisions a trusted certificate automatically:

```bash
tailscale serve --bg --https=443 http://127.0.0.1:4000
# then in earss.env:
# EARSS_TTS_PUBLIC_URL=https://<machine>.<tailnet>.ts.net
```

After changing `EARSS_TTS_PUBLIC_URL`, **remove and re-add the podcast** in
Apple Podcasts — it caches enclosure URLs aggressively.

## Security notes

The podcast endpoints (`/podcast/rss.xml`, `/podcast/audio/*`,
`/podcast/cover.jpg`) and `/tts/listen/*` are **unauthenticated by design**
(podcast clients and Apple's crawler cannot log in; see decision D5 in
`data_model.md`). Exposure:

- The feed lists the synthesized listening queue (titles + original links)
  and the audio of entries you requested — nothing else. No admin surface,
  no credentials, no other entries.
- Media filenames are validated against a strict whitelist
  (`^\d+\.(mp3|m4a|…)$`) and matched against `ready` rows only.
- `/tts/listen` requires a valid HMAC signature; forged links get 403.
- Keep the feed URL private the way you would any capability URL. On a
  tailnet-only `tailscale serve` the audience is just your own devices.

## Worker configuration

`config :earss, :tts, worker:` (defaults in `config/config.exs`):

| Key | Default | Meaning |
|-----|---------|---------|
| `interval_ms` | 30_000 | Tick cadence |
| `batch_size` | 5 | Rows claimed per tick |
| `max_retries` | 5 | Attempts before `failed` |
| `max_chars_sync` | 100_000 | Sync path threshold (align with the provider's own limit) |
| `poll_interval_ms` / `poll_attempts` | 2_000 / 60 | Async job polling |
| `processing_lease_secs` | 1_800 | Requeue rows stuck in `processing` after a crash |

Rows whose processing lease expires are requeued with the expiry counted as
an attempt, so a permanently failing entry settles in `failed` instead of
looping. `max_concurrency` (top level, default 1) caps in-flight provider
calls; async job polling holds its slot for the whole poll window.

## Retention

Levels D and E of `Earss.Retention` (see [data_lifecycle.md](data_lifecycle.md))
bound audio growth:

- **Level D** — `ready` rows older than `tts_audio_days` (default **90**) are
  deleted together with their audio files. `requested`/`processing`/`failed`
  rows are never touched. Re-synthesizing after expiry is allowed: with the
  row gone, clicking the listen control records a fresh request.
- **Level E** — audio files with no live row (cascade orphans from entry
  purge, worker crash leftovers) are swept when older than
  `tts_orphan_grace_hours` (default 24, covering the worker's
  write-then-mark-ready span).

Set `EARSS_TTS_AUDIO_RETENTION_DAYS=0` to disable expiry entirely. Audio
files live outside PostgreSQL — they are **not** covered by `pg_dump`
([backup.md](backup.md)).

## Admin

The **Listen** page (`/admin/tts`, nav entry shown only when TTS is
configured) covers day-to-day operation:

- queue stats: ready / requested / processing / failed counts and total
  audio bytes on disk
- provider table and worker configuration line, with warnings for the
  known misconfigurations (worker on without a provider or audio_dir;
  missing public_url; plain-HTTP media that Apple Podcasts won't play)
- requests table (most recent first): state tabs, entry link, provider,
  size, estimated duration, error — with per-row **Retry** / **Delete**
  and batch actions. Retry fully resets a row (backoff and attempt
  count) so the worker picks it up on its next tick; Delete removes the
  row and its audio file (the entry can be re-requested later).

`/admin/system` shows the merged `:tts` config and the retention level
D/E knobs.
