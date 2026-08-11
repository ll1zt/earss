defmodule Earss.Source.Enricher do
  @moduledoc """
  Behaviour for **content enrichment** providers: built-in and external
  plugins (translation, TTS, …).

  This is the DB-facing contract — stricter than `Earss.Source.Adapter`
  (which feeds content *in*): an enricher consumes an entry's fields and
  produces enriched fields the host stores verbatim. The host owns the
  database, the pending/publish lifecycle and retries; the plugin owns the
  domain algorithm (how content is turned into its enriched form — HTML
  block handling for translation, audio synthesis for TTS, …).

  Plugins depend on **`:earss_source` only**, implement this behaviour, and
  register with the host app's `Earss.Enrichment.Registry` at runtime — the
  enrichment twin of `Earss.Source.Registry` for feed adapters.

  ## Adapter API version

  Return `adapter_api/0` equal to `#{__MODULE__}.api_version/0` (currently
  **1**). Hosts refuse providers with an unsupported version.

  ## Content opacity

  Entry content passed to `enrich/2` is **opaque**: the host never parses or
  inspects the HTML. Splitting content into provider-friendly units, calling
  the provider, and reassembling the result is entirely the plugin's job. The
  host only validates the *shape* of what comes back (see contract rules).

  ## Contract rules (host-enforced)

    * every `:ref` in the input must be echoed back **exactly once** in the
      result — missing, duplicated or foreign refs make the whole batch
      `{:error, :ref_mismatch}` and nothing is stored
    * result `:title`/`:summary`/`:content` must be strings or `nil` —
      anything else rejects the batch
    * `:meta` is an opaque map stored verbatim alongside the result
    * returning `{:error, term()}` means "nothing in this batch was
      produced" — the host keeps the entry pending and retries later

  ## `skip?/2`

  Optional cheap local pre-filter the host runs **before** spending an
  `enrich/2` call: return `true` when the payload does not need enrichment
  for the given opts (e.g. already written in the target language). The
  default returns `false` (never skip).

  ## `split_blocks/1`

  Optional structural helper for hosts that need block-level presentation
  (e.g. the interleaved layout): split enriched HTML back into its
  block-level units. The plugin knows its own output structure best. Hosts
  probe with `function_exported?/3` and fall back gracefully (a layout that
  needs it degrades to a simpler one).

  ## Translation

  Common `opts` (translation plugins):

    * `:target_lang` — BCP-47 target language (required for translation)
    * `:source_lang` — optional source language hint (`nil` = auto-detect)
    * `:model` — optional model override
    * `:timeout_ms` — per-request timeout
    * `:max_chars` — maximum total input characters accepted
  """

  @api_version 1

  @doc "Current contract major version implemented by this package."
  @spec api_version() :: pos_integer()
  def api_version, do: @api_version

  @typedoc "One entry payload; `:ref` is host-generated and must be echoed back."
  @type payload :: %{
          required(:ref) => term(),
          optional(:title) => String.t() | nil,
          optional(:summary) => String.t() | nil,
          optional(:content) => String.t() | nil
        }

  @typedoc "One enriched entry; `:ref` set must match the input ref set exactly."
  @type enriched :: %{
          required(:ref) => term(),
          optional(:title) => String.t() | nil,
          optional(:summary) => String.t() | nil,
          optional(:content) => String.t() | nil,
          optional(:meta) => map()
        }

  @typedoc "Provider metadata for admin UIs and docs."
  @type provider_info :: %{
          required(:name) => String.t(),
          optional(:base_url) => String.t() | nil,
          optional(:model) => String.t() | nil
        }

  @doc "Stable provider id (e.g. `\"openai\"`)."
  @callback id() :: String.t()

  @doc """
  Contract version this module implements — use `Earss.Source.Enricher.api_version/0`.

      iex> Earss.Source.Enricher.api_version()
      1
  """
  @callback adapter_api() :: pos_integer()

  @doc "Provider metadata for admin UIs and docs."
  @callback provider_info() :: provider_info()

  @doc """
  Enrich a batch of entries (see `t:payload/0` and `t:enriched/0`).

  Returns `{:ok, [enriched()]}` or `{:error, term()}`. The host batches by
  its own budget; plugins may further split/batch provider calls internally
  (e.g. greedy packing by item count and char count).
  """
  @callback enrich(payloads :: [payload()], opts :: keyword()) ::
              {:ok, [enriched()]} | {:error, term()}

  @doc """
  Optional pre-filter: does `payload` already need no enrichment for `opts`?

  The host runs this per payload before spending a provider call. The
  default returns `false` (never skip).
  """
  @callback skip?(payload :: payload(), opts :: keyword()) :: boolean()

  @doc """
  Optional block splitter: split enriched HTML back into block-level units.

  Used by hosts for block-level presentation (e.g. interleaved layout).
  Returns `{:ok, [String.t()]}` or `{:error, term()}`.
  """
  @callback split_blocks(html :: String.t()) :: {:ok, [String.t()]} | {:error, term()}

  @doc "Default `skip?/2`: never skip (plugins opt into heuristics)."
  @spec skip?(payload(), keyword()) :: boolean()
  def skip?(_payload, _opts), do: false

  @optional_callbacks skip?: 2, split_blocks: 1
end
