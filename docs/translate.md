# Translation (Goal 2)

Earss can translate feed content into a target language at ingest time using
a pluggable **translator** (contract: `Earss.Source.Translator` in the
`earss_source` package). Reference implementation:
[`earss_translate_openai`](../earss_translate_openai) (OpenAI-compatible APIs).

> ⚠️ **Privacy warning — please read.**
> When translation is enabled, **entry title/summary/content are sent to the
> configured provider** (an external LLM API unless you self-host one such as
> Ollama/vLLM). Earss never sends your API key to anyone, but the **content
> itself leaves your server**. Only enable translation for feeds you are
> comfortable sharing, and choose a provider you trust. Translated copies
> are stored locally; disabling translation does not delete existing
> translations (see Backfill).

## How it works

```
feed.translate_to = "zh"  (or a per-subscription override)
        │ ingest (new entries) / admin backfill (existing)
        ▼
Earss.Translate  →  build one batched provider call per entry
                   (title + summary + HTML content blocks)
        │
        ▼
entry_translations (entry_id, lang, title, summary, content,
                    original_hash, model, translated_at)
        │
        ▼
GReader / Fever / JSON API  →  translation view replaces title/content
```

* Original `entries` rows are **never mutated**; translations live in a
  separate table keyed by `(entry_id, lang)` — one feed can carry several
  target languages.
* **Idempotent**: entries whose `content_hash` matches the stored
  `original_hash` are skipped; re-running backfill only adds what's missing.
* **Never blocks ingestion**: provider errors are recorded in
  `feeds.translate_error_count` and the original text is kept.
* **Language skip**: a local heuristic (CJK/kana/hangul script ratio) plus
  the plugin's optional `skip?/2` avoid translating content that is already
  in the target language.

## Enabling translation

Requires a loaded translator plugin (see `/admin/translate` — it shows the
installed plugin, enabled feeds and per-subscription overrides, or a
"no plugin loaded" hint).

### Feed level (shared by all readers)

`/admin/subscriptions/<id>` → "Feed translation" form, or via category
batch on `/admin/categories` (applies one target to every feed in the
category). New entries are translated on ingest; existing entries need
**Backfill now** (or the async backfill that runs when you save).

### Subscription level (per account)

`/admin/subscriptions/<id>` → "Subscription translation" form. Set a target
language (overrides the feed for this account only) and optionally keep the
original appended after the translation:

```
译文 HTML <hr class="earss-original"> 原文 HTML
```

Saving an override starts a background backfill of existing entries.

### Feed level append-original

The feed translation form has the same "also append the original" toggle
(`feeds.return_original`, default off) — a feed-level translation can output
译文 + separator + 原文 for **all** readers. Subscription overrides append by
default; feed-level opt-in applies to everyone.

## Reading the translations

Protocol clients (NetNewsWire, Reeder, …) need **no configuration**: when a
translation exists for the target language, GReader stream contents and
`items/contents` (and the Fever items endpoint) return the translated
title/summary/content directly. Target language resolution per row:
`subscription.translate_to` (the requesting user's override) → then
`feed.translate_to`.

* `?original=1` on GReader stream/items (and Fever) returns the original
  text — the escape hatch for scripts.
* JSON API: `GET /api/entries?translate_to=zh` adds
  `title_translated` / `summary_translated` / `content_translated` keys
  (omitted when no translation exists; original fields stay untouched).
* Feed-level translation is a **content fact**: it applies to every reader
  and is never concatenated with the original. Concatenation only happens
  for per-subscription overrides with "append original" enabled.

### Client cache refresh (backfill of old articles)

Storing a translation **touches the entry's `updated_at`**, so GReader
responses advertise a newer `updated` for that item. NetNewsWire and similar
clients key their local cache refresh on this timestamp — without it, an
article cached before its translation would stay at the original text even
after the protocol starts serving the translation.

In practice:

* a **list refresh / re-sync** in the client picks up translated content for
  entries whose `updated` changed (translations are written with a real
  provider delay, so this is normally a visible change)
* an article opened **before** its translation finished may still show the
  cached original until the next sync; some clients need a forced refresh or
  mark-as-unread to re-fetch a single item — this is client-side caching
  behaviour, earss only provides the correct update signal

## Plugin install

```bash
# earss.env
EARSS_TRANSLATE_PLUGINS=path:../earss_translate_openai
EARSS_TRANSLATE_OPENAI_API_KEY=sk-...
EARSS_TRANSLATE_OPENAI_MODEL=gpt-4o-mini
```

Spec grammar is the same as `EARSS_SOURCE_PLUGINS` (github/git/hex/path).
Multiple translators are allowed; the first registered by id is the default.
The reference plugin also accepts `EARSS_TRANSLATE_OPENAI_BASE_URL`
(DeepSeek/Ollama/vLLM), `EARSS_TRANSLATE_OPENAI_JSON_MODE`, batching and
timeout knobs — see its `README.md`.

## HTML structure preservation

Block-level elements (`p`, `h1–h6`, `li`, `blockquote`, …) are translated as
units; inline markup (`a`, `strong`, `em`, `img`, …) becomes `⟦n⟧` placeholder
tokens whose original markup is preserved verbatim; `pre`/`code` are never
translated. After translation the placeholders are validated (all present, no
extras) before markup is restored — a corrupted response degrades to the
original block rather than broken HTML.

## Backfill

`Earss.Translate.backfill_feed/2` pages through all entries of a feed inside
a transaction (idempotent). Admin "Backfill now" runs it synchronously;
saving feed/subscription/category settings triggers
`Earss.Translate.backfill_async/2` (detached task, results logged).

## Operations

* Budget: `config :earss, :translate, budget: %{max_entries: 20, max_chars: 100_000}`
  caps how many new entries a single ingest cycle translates.
* **Concurrency**: all provider requests go through a global FIFO limiter
  (`Earss.Translate.Limiter`); `config :earss, :translate, max_concurrency: 1`
  (default) serializes calls so parallel feed polling + admin backfills never
  burst the provider. Raise it for providers that handle parallel requests.
* **Visibility window**: entries of a translated feed are hidden from
  protocol clients until their translation exists (or the window expires,
  default 15 minutes via `:visibility_window_minutes`). This prevents GReader
  clients from caching the untranslated original forever — see
  "Client cache refresh" above.
* Errors: `feeds.translate_error_count` (visible on the subscription page and
  `/admin/translate`); it never disables the feed.
* Backfill pages with short queries; each translation persists in its own
  short transaction, so a slow provider neither blocks other requests nor
  rolls back already-stored translations. The admin button runs it in a
  background task.
* Deleting an entry cascades its translations (`on_delete: :delete_all`).
