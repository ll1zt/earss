defmodule EarssSource do
  @moduledoc """
  Contract package for Earss source adapters (plugins).

  Plugins should depend on **`:earss_source` only**, implement
  `Earss.Source.Adapter`, and register with the host app's registry at
  runtime. See the Earss repo doc `docs/sources.md` (R1 + C2).

  Current behaviour API version: `#{Earss.Source.Adapter.api_version()}`.
  """

  def adapter_api_version, do: Earss.Source.Adapter.api_version()
end
