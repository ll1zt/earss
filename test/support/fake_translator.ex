defmodule Earss.Test.FakeTranslator do
  @moduledoc """
  Test-only `Earss.Source.Translator` with behavior switched via the calling
  process dictionary:

    * `Process.put(:fake_behavior, :normal)` (default) — prefix every item
      with `[译]`, placeholders preserved verbatim
    * `:drop_placeholder` — strip `⟦n⟧` tokens (models a model corrupting
      markup; the host must fall back to the original block)
    * `:error` — return `{:error, :provider_down}`
    * `:skip_all` — return an empty translation list

  `skip?/2` returns true when `:fake_skip` is set and the text contains
  `"SKIPME"`.
  """

  @behaviour Earss.Source.Translator

  @impl true
  def id, do: "test_translator"

  @impl true
  def adapter_api, do: Earss.Source.Translator.api_version()

  @impl true
  def provider_info, do: %{name: "Fake", base_url: nil, model: "fake"}

  @impl true
  def translate(items, _opts) do
    case Process.get(:fake_behavior, :normal) do
      :drop_placeholder ->
        {:ok,
         Enum.map(items, fn item ->
           %{key: item.key, translated: String.replace(item.text, ~r/⟦\d+⟧/, "X")}
         end)}

      :error ->
        {:error, :provider_down}

      :skip_all ->
        {:ok, []}

      _ ->
        {:ok, Enum.map(items, fn item -> %{key: item.key, translated: "[译]" <> item.text} end)}
    end
  end

  @impl true
  def skip?(text, _target_lang) do
    Process.get(:fake_skip, false) and String.contains?(text, "SKIPME")
  end
end
