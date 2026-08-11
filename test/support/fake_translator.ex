defmodule Earss.Test.FakeTranslator do
  @moduledoc """
  Test-only `Earss.Source.Enricher` with behavior switched via the calling
  process dictionary:

    * `Process.put(:fake_behavior, :normal)` (default) — prefix every field
      with `[译]`
    * `:error` — return `{:error, :provider_down}`
    * `:error_on_bad` — return `{:error, :bad}` when any payload content
      contains `"BAD"`, enrich the rest normally
    * `:skip_all` — return `{:ok, []}` (ref mismatch; the host must reject)

  `skip?/2` returns true when `:fake_skip` is set and a payload field
  contains `"SKIPME"`.

  `split_blocks/1` splits on `<p>`/`<li>`/`<h1-6>` blocks — enough for the
  interleaved layout tests.
  """

  @behaviour Earss.Source.Enricher

  @impl true
  def id, do: "test_translator"

  @impl true
  def adapter_api, do: Earss.Source.Enricher.api_version()

  @impl true
  def provider_info, do: %{name: "Fake", base_url: nil, model: "fake"}

  @impl true
  def enrich(payloads, _opts) do
    case Process.get(:fake_behavior, :normal) do
      :error ->
        {:error, :provider_down}

      :error_on_bad ->
        if Enum.any?(payloads, fn p -> String.contains?(sample(p), "BAD") end) do
          {:error, :bad}
        else
          enrich_normal(payloads)
        end

      :skip_all ->
        {:ok, []}

      _ ->
        enrich_normal(payloads)
    end
  end

  defp enrich_normal(payloads) do
    {:ok,
     Enum.map(payloads, fn p ->
       %{
         ref: p.ref,
         title: prefix(p.title),
         summary: prefix(p.summary),
         content: prefix(p.content),
         meta: %{model: id()}
       }
     end)}
  end

  defp prefix(nil), do: nil
  defp prefix(""), do: ""
  defp prefix(text), do: "[译]" <> text

  @impl true
  def skip?(payload, _opts) do
    Process.get(:fake_skip, false) and String.contains?(sample(payload), "SKIPME")
  end

  @impl true
  def split_blocks(html) when is_binary(html) do
    blocks =
      ~r/<p[^>]*>.*?<\/p>|<li[^>]*>.*?<\/li>|<h[1-6][^>]*>.*?<\/h[1-6]>/
      |> Regex.scan(html, capture: :first)
      |> List.flatten()

    {:ok, blocks}
  end

  defp sample(payload) do
    [payload[:title], payload[:summary], payload[:content]]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end
end
