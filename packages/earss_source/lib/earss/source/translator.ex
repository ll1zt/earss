defmodule Earss.Source.Translator do
  @moduledoc """
  Behaviour for content translation providers: built-in and external plugins.

  Plugins depend on **`:earss_source` only**, implement this behaviour, and
  register with the host app's `Earss.Translate.Registry` at runtime — the
  translation twin of `Earss.Source.Registry` for feed adapters.

  ## Adapter API version

  Return `adapter_api/0` equal to `#{__MODULE__}.api_version/0` (currently **1**).
  Hosts may refuse translators with an unsupported version.

  ## Keys and batching

  The host batches one entry's title + summary + content blocks into a single
  `translate/2` call. Each input item carries a host-generated `:key` (e.g.
  `"t"`, `"s"`, `"b0"`, `"b1"`) that must be **echoed back verbatim** in the
  result so the host can map translations back to entry fields. Keys are
  opaque to the plugin.

  ## `skip?/2`

  Cheap local pre-filter run by the host **before** spending an API call:
  return `true` when `text` is already in `target_lang`. The default returns
  `false` (never skip); plugins may implement a heuristic (e.g. CJK ratio for
  `zh` targets). Hosts combine this with their own built-in heuristics.
  """

  @api_version 1

  @doc "Current contract major version implemented by this package."
  @spec api_version() :: pos_integer()
  def api_version, do: @api_version

  @typedoc "One text unit to translate, keyed by the host."
  @type item :: %{required(:key) => String.t(), required(:text) => String.t()}

  @typedoc "One translated text unit; `:key` echoes the input item's key."
  @type translated :: %{required(:key) => String.t(), required(:translated) => String.t()}

  @typedoc "Provider metadata for admin UIs and docs."
  @type provider_info :: %{
          required(:name) => String.t(),
          optional(:base_url) => String.t() | nil,
          optional(:model) => String.t() | nil
        }

  @doc "Stable translator id (e.g. `\"openai\"`)."
  @callback id() :: String.t()

  @doc """
  Contract version this module implements — use `Earss.Source.Translator.api_version/0`.

      iex> Earss.Source.Translator.api_version()
      1
  """
  @callback adapter_api() :: pos_integer()

  @doc "Provider metadata for admin UIs and docs."
  @callback provider_info() :: provider_info()

  @doc """
  Cheap local pre-filter: is `text` already in `target_lang` (skip translation)?

  The host runs this per text unit before spending an API call. The default
  returns `false` (never skip); plugins implement heuristics to opt in.

      iex> Earss.Source.Translator.skip?("hello world", "zh")
      false
  """
  @callback skip?(text :: String.t(), target_lang :: String.t()) :: boolean()

  @doc """
  Translate a batch of text items.

  `items` are `%{key: key, text: text}` pairs; `key` is host-generated and must
  be echoed back verbatim in the result. Returning fewer/more items than
  requested, or dropping a key, is a contract violation the host must handle
  defensively (e.g. fall back to the original text).

  Common `opts`:

    * `:target_lang` — BCP-47 target language (required)
    * `:source_lang` — optional source language hint (`nil` = auto-detect)
    * `:model` — optional model override
    * `:timeout_ms` — per-request timeout
    * `:max_chars` — maximum total input characters accepted

  Returns `{:ok, translations}` or `{:error, term()}` (network, rate limit,
  timeout, malformed response). The host never blocks ingestion on errors —
  it records them and keeps the original text.
  """
  @callback translate(items :: [item()], opts :: keyword()) ::
              {:ok, [translated()]} | {:error, term()}

  @doc "Default `skip?/2`: never skip (plugins opt into heuristics)."
  @spec skip?(String.t(), String.t()) :: boolean()
  def skip?(_text, _target_lang), do: false
end
