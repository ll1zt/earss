# Translation (Goal 2)

Earss can translate feed content into a target language at ingest time using
a pluggable **enricher** (contract: `Earss.Source.Enricher` in the
`earss_source` package — the same contract serves future enrichment kinds
like TTS). Reference implementation:
[`earss_translate_openai`](../earss_translate_openai) (OpenAI-compatible APIs).

> ⚠️ **Privacy warning — please read.**
> When translation is enabled, **entry title/summary/content are sent to the
> configured provider** (an external LLM API unless you self-host one such as
> Ollama/vLLM). Earss never sends your API key to anyone, but the **content
> itself leaves your server**. Only enable translation for feeds you are
> comfortable sharing, and choose a provider you trust. Translated copies
> are stored locally; disabling translation makes the original text visible
> again.

## Division of labour

* **Host (`Earss.Enrichment`)** — the DB-facing half: which entries are
  pending, when they become visible, retry/give-up policy, storage of the
  enriched fields, protocol view, admin UI. Entry content is **opaque** to
  the host; it never parses HTML.
* **Plugin (`Earss.Source.Enricher` implementation)** — the domain
algorithm: splitting content into translatable units, calling the provider,
reassembling the result, skip heuristics, and (for the interleaved layout)
block splitting. The host validates the result shape (ref set, field types)
and rejects a batch that violates the contract.

## How it works

```
feed.translate_to = "zh"  (or a per-subscription override)
        │ ingest: new entries are flagged translation_pending_at
        │ (hidden from protocol clients) and translated
        ▼
Earss.Enrichment  →  packs entry fields opaquely → plugin enrich/2
                   (plugin: one batched provider call per entry,
                    title + summary + HTML content blocks)
        │
        ▼
entry_translations (entry_id, lang, title, summary, content,
                    original_hash, model, translated_at)
        │  every target language ready → pending flag cleared
        ▼
GReader / Fever / JSON API  →  translation view replaces title/content
```

* **Publish model**: new entries of translated feeds are **hidden until their
  translations are ready** (`entries.translation_pending_at`) — protocol
  clients only ever see the final form, so they never cache an untranslated
  original (NetNewsWire caches the first version it sees). Failed
  translations stay pending and are retried by
  `Earss.Enrichment.PendingWorker` (periodic, default 60s); disabling a
  feed's translation clears its pending flags and the original text becomes
  visible again.
* Original `entries` rows are **never mutated**; translations live in a
  separate table keyed by `(entry_id, lang)` — one feed can carry several
  target languages.
* **Idempotent**: entries whose `content_hash` matches the stored
  `original_hash` are skipped. A re-fetch that merely re-upserts unchanged
  rows never re-flags already-published entries.
* **Never blocks ingestion**: the ingest hook flags new entries pending
  synchronously, then enriches **asynchronously** under the
  `Enrichment.TaskSupervisor` — the feed refresh returns immediately and is
  never held hostage by slow provider calls. Provider errors are recorded in
  `feeds.translate_error_count` and the entry stays pending for retry.
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
category). New entries are translated as they are fetched; **existing
entries stay in the original language**.

### Subscription level (per account)

`/admin/subscriptions/<id>` → "Subscription translation" form. Set a target
language (overrides the feed for this account only) and choose an **original
text layout** (default `inline`: `译文<hr class="earss-original">原文`;
see the layout table below). New entries are translated as they are fetched.

### Feed level append-original

The feed translation form has the same "original text layout" selector
(`feeds.original_layout`, default `off`) — a feed-level translation can
attach the original for **all** readers. Subscription overrides default to
`inline`; feed-level opt-in applies to everyone.

### Original text layouts

Both feed- and subscription-level configuration use the same layout enum:

| Layout | Output |
|--------|--------|
| `off` | translation only |
| `inline` | `译文<hr class="earss-original">原文` (default for overrides) |
| `section` | translation, separator, then the original wrapped in `<div class="earss-original-section">` |
| `interleaved` | paragraph-by-paragraph alternation (`译文段` + `<div class="earss-original-block">原文段</div>`); reliable because translated content is reassembled with the original block tags, so block counts line up. The block splitter is resolved from the stored `enricher_id` (the plugin that produced the translation); rows without one (pre-migration) degrade to `section` |

### Source language

`translate_from` is optional. Leave it blank for **automatic detection** —
the provider prompt asks the model to translate "from the original language",
so the source is inferred per entry. Fill it in (e.g. `ja`) only when you want
an explicit hint (rarely needed).

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

### Client cache refresh

Storing a translation **touches the entry's `updated_at`**, so GReader
responses advertise a newer `updated` for that item — useful for clients
that honour it. NetNewsWire does not parse `updated`; it refreshes only
articles missing locally, which is exactly why the pending model hides
untranslated entries until they are ready.

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

Translation plugins are **optional Mix deps**: they are compiled but not
hard-started by OTP (`runtime: false`), so **earss boots fine without them**
and the admin console simply omits all translation UI (no nav link, no
forms, no category buttons) until a translator is loaded. `/admin/translate`
still exists as a guide page when no plugin is present.

Changing `EARSS_TRANSLATE_PLUGINS` (adding or removing a plugin) requires
`mix deps.get && mix compile`; once compiled, removing the plugin entry
does not stop the app from booting even before recompiling.

## HTML structure preservation

Block-level elements (`p`, `h1–h6`, `li`, `blockquote`, …) are translated as
units; inline markup (`a`, `strong`, `em`, `img`, …) becomes `⟦n⟧` placeholder
tokens whose original markup is preserved verbatim; `pre`/`code` are never
translated. After translation the placeholders are validated (all present, no
extras) before markup is restored — a corrupted response degrades to the
original block rather than broken HTML.

## Operations

* Budget: `config :earss, :translate, budget: %{max_entries: 20, max_chars: 100_000}`
  caps how many new entries a single ingest cycle translates — by entry
  count **and** cumulative input size in characters (`max_chars: 0` =
  unlimited); entries beyond the budget stay pending and are picked up by
  the pending worker.
* **Pending retry**: `Earss.Enrichment.PendingWorker` (default 60s interval,
  `config :earss, :translate, pending_worker: %{interval_ms: …}`) retries
  entries whose translation failed. After `max_pending_retries` (default 5)
  consecutive failures the entry **pauses** (`translation_paused_at`): it
  stays hidden (pending kept) and is **not retried** until an admin decides on
  the subscription page or `/admin/translate` — **Re-translate paused**
  clears the pause and resumes, **Publish pending (no translate)** clears the
  pending flags so the originals become visible. Status (processing / paused
  counts) is shown per feed. There is **no backfill** — existing entries stay
  in the original language by design.
* **Multiple models**: the reference plugin falls back across an ordered
  model chain (`EARSS_TRANSLATE_OPENAI_MODELS=primary@url,backup`, priority
  order) when a model fails (quota, 5xx, timeout); `meta.model` records the
  model that actually served each translation.
* **Concurrency**: all provider requests go through a global FIFO limiter
  (`Earss.Enrichment.Limiter`); `config :earss, :translate, max_concurrency: 1`
  (default) serializes calls so parallel feed polling + pending retries never
  burst the provider. Raise it for providers that handle parallel requests.
* Errors: `feeds.translate_error_count` (visible on the subscription page and
  `/admin/translate`); it never disables the feed.
* **No duplicate originals**: when the stored content already equals the
  original (e.g. a Chinese source with a `zh` target, where the plugin stores
  an original-text copy), layouts that append the original render it once
  instead of duplicating it.
* Deleting an entry cascades its translations (`on_delete: :delete_all`).
