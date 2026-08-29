defmodule Earss.TTS.Provider do
  @moduledoc """
  Behaviour for **text-to-speech providers**: the audio twin of
  `Earss.Source.Enricher` (docs/translate.md; TTS is the audio twin of the
  enrichment pipeline).

  A provider turns article text into audio bytes. The host owns the
  database (tts_requests), the trigger (the injected listen control), the retry/publish
  lifecycle and the podcast feed; the provider owns the domain algorithm
  (how text maps onto its API, chunking, voice selection,
  provider calls).

  ## API version

  Return `adapter_api/0` equal to `#{__MODULE__}.api_version/0` (currently
  **1**). Hosts refuse providers with an unsupported version.

  ## Two paths

    * **Synchronous** (`synthesize/2`): short text → audio bytes in one
      call. Required.
    * **Asynchronous jobs** (`submit/2`, `poll/2`, `download/2`): long
      text that the provider cannot or should not synthesize in one
      request. Optional; the host falls back to `synthesize/2` (or queues
      a retry) when absent.

  ## Contract rules (host-enforced later, keep in mind)

    * `synthesize/2` returns audio **bytes** plus `content_type`; never
      files, paths or side effects.
    * `submit/2` returns a provider-side `job_id`; `poll/2` reports
      `:pending | :processing | :ready | :failed`; `download/2` returns
      the finished audio.
    * `{:error, term()}` means "nothing produced" — the host keeps the job
      queued and retries later.

  ## Parameters

  `t:params/0` carries the common semantic parameters; the host does not
  interpret anything beyond these. Provider-specific knobs travel in
  `opts` (typically resolved from `EARSS_TTS_*` env by the provider).
  """

  @api_version 1

  @doc "Current contract major version implemented by this package."
  @spec api_version() :: pos_integer()
  def api_version, do: @api_version

  @typedoc "Common semantic parameters for one synthesis request."
  @type params :: %{
          required(:text) => String.t(),
          optional(:lang) => String.t() | nil,
          optional(:voice_key) => String.t() | nil,
          optional(:format) => String.t() | nil,
          optional(:duration_hint) => pos_integer() | nil
        }

  @typedoc "Synthesized audio result."
  @type audio_result :: %{
          required(:audio) => binary(),
          required(:content_type) => String.t(),
          optional(:meta) => map()
        }

  @typedoc "Provider metadata for admin UIs and docs."
  @type provider_info :: %{
          required(:name) => String.t(),
          optional(:base_url) => String.t() | nil,
          optional(:model) => String.t() | nil
        }

  @typedoc "Async job status reported by `poll/2`."
  @type job_status :: :pending | :processing | :ready | :failed

  @doc "Stable provider id (e.g. `\"fish\"`)."
  @callback id() :: String.t()

  @doc "Contract version this module implements — use `Earss.TTS.Provider.api_version/0`."
  @callback adapter_api() :: pos_integer()

  @doc "Provider metadata for admin UIs and docs."
  @callback provider_info() :: provider_info()

  @doc """
  Synthesize text to audio in one call (short text).

  Returns `{:ok, audio_result()}` or `{:error, term()}`.
  """
  @callback synthesize(params :: params(), opts :: keyword()) ::
              {:ok, audio_result()} | {:error, term()}

  @doc """
  Submit long text as an asynchronous job; returns a provider-side
  `job_id` the host stores verbatim.
  """
  @callback submit(params :: params(), opts :: keyword()) ::
              {:ok, %{job_id: String.t()}} | {:error, term()}

  @doc "Poll an async job; see `t:job_status/0`."
  @callback poll(job_id :: String.t(), opts :: keyword()) ::
              {:ok, job_status(), map()} | {:error, term()}

  @doc "Download finished audio for an async job."
  @callback download(job_id :: String.t(), opts :: keyword()) ::
              {:ok, audio_result()} | {:error, term()}

  @optional_callbacks submit: 2, poll: 2, download: 2
end
