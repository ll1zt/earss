defmodule Earss.Test.FakeTranslator do
  @moduledoc """
  Test-only `Earss.Source.Translator` with behavior switched via the calling
  process dictionary:

    * `Process.put(:fake_behavior, :normal)` (default) — prefix every item
      with `[译]`, placeholders preserved verbatim
    * `:drop_placeholder` — strip `⟦n⟧` tokens (models a model corrupting
      markup; the host must fall back to the original block)
    * `:error` — return `{:error, :provider_down}`
    * `:error_on_bad` — return `{:error, :bad}` for items whose text contains
      `"BAD"`, translate the rest normally
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

      :error_on_bad ->
        case Enum.find(items, fn item -> String.contains?(item.text, "BAD") end) do
          nil -> translate_normal(items)
          _ -> {:error, :bad}
        end

      :skip_all ->
        {:ok, []}

      _ ->
        translate_normal(items)
    end
  end

  defp translate_normal(items) do
    {:ok, Enum.map(items, fn item -> %{key: item.key, translated: "[译]" <> item.text} end)}
  end

  @impl true
  def skip?(text, _target_lang) do
    Process.get(:fake_skip, false) and String.contains?(text, "SKIPME")
  end
end
