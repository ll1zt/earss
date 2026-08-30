defmodule EarssTts do
  @moduledoc """
  Contract package for Earss TTS providers (plugins).

  Plugins should depend on **`:earss_tts` only**, implement
  `Earss.TTS.Provider`, and register with the host app's registry at
  runtime (host side lands with the core orchestration — see
  the host TTS orchestration).

  The API is modeled on the Fish Audio OpenAPI schema
  (https://api.fish.audio/openapi.json) but deliberately **provider-agnostic**:
  a provider maps the common semantic parameters (`text`, `lang`,
  `voice_key`, `format`) onto its own API, and passes through any
  provider-specific parameters via `opts` (typically env-driven).

  ## Modules

    * `Earss.TTS.Provider` — behaviour (`adapter_api` = `#{Earss.TTS.Provider.api_version()}`)
    * `Earss.TTS.Lang` — language detection heuristics (CJK / kana / hangul)
    * `Earss.TTS.Audio` — audio helpers (content types, duration hints)

  ## Author checklist (short)

  1. Depend only on `:earss_tts` (not private `Earss.*` host modules).
  2. Implement `id/0`, `adapter_api/0`, `provider_info/0`, `synthesize/2`.
  3. Long text? Implement `submit/2`, `poll/2`, `download/2` (async jobs).
  4. Return audio **bytes** with `content_type`; never write files or DB.
  5. Read configuration from the operator environment (`EARSS_TTS_*`),
     with per-call `opts` overrides (tests inject a Bypass URL this way).
  """

  def adapter_api_version, do: Earss.TTS.Provider.api_version()
end
