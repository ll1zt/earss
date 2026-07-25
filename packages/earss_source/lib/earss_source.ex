defmodule EarssSource do
  @moduledoc """
  Contract package for Earss source adapters (plugins).

  Plugins should depend on **`:earss_source` only**, implement
  `Earss.Source.Adapter`, and register with the host app's registry at
  runtime. See the Earss repo doc `docs/sources.md` (R1 + C2).

  ## Modules

    * `Earss.Source.Adapter` — behaviour (`adapter_api` = `#{Earss.Source.Adapter.api_version()}`)
    * `Earss.Source.Politeness` — pure helpers (intervals, host keys, Retry-After)

  ## Author checklist (short)

  1. Depend only on `:earss_source` (not private `Earss.*` host modules).
  2. Implement `id/0`, `adapter_api/0`, `routes/0`, `resolve/1`, `fetch/2`.
  3. Canonical identity is `earss://<id>/…` (R1); keep `source_url` stable for OPML.
  4. Use `Earss.Source.Politeness` for conservative intervals and Retry-After.
  5. Register on host `Earss.Source.Registry` at app start (or rely on host
     discovery for apps named `earss_source_*` exporting `*.Adapter`).
  6. Never write to the DB from the adapter; return data only.
  """

  def adapter_api_version, do: Earss.Source.Adapter.api_version()
end
