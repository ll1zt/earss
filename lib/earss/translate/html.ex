defmodule Earss.Translate.HTML do
  @moduledoc """
  Block-preserving HTML translation support (Goal 2, docs/translate.md).

  Splits HTML into translatable text blocks so the host can batch them into a
  single provider call, then reassembles translations back into the original
  structure:

    * block-level elements (`p`, `h1`-`h6`, `li`, `blockquote`, `figcaption`,
      `td`, `th`, `dt`, `dd`) are translation units
    * inline elements (`a`, `strong`, `em`, `img`, `code`, ...) become `⟦n⟧`
      placeholder tokens whose **original markup is preserved verbatim**
      (hrefs, sources, emphasis) — the host's prompt tells the model to keep
      placeholders untouched
    * style-only tags (`b`, `i`, `u`, `span`) are unwrapped so their text is
      translated with the surrounding block
    * `pre`/`code` blocks are never translated (code stays code)
    * after translation, placeholders are validated (all present, none
      dropped/duplicated) before markup is restored; on any mismatch the
      caller falls back to plain text via `to_plain_text/1`

  The module is pure (no I/O) and deterministic.
  """

  @block_tags ~w(p h1 h2 h3 h4 h5 h6 li blockquote figcaption td th dt dd)
  @container_tags ~w(div span section article main header footer ul ol table tr thead tbody)
  @raw_tags ~w(pre code)
  # Semantically meaningful inline elements: kept as placeholders (text not
  # translated, markup preserved). Style-only tags below are unwrapped instead.
  @placeholder_tags ~w(a strong em code br img sup sub small mark time abbr kbd samp var q cite)
  @unwrap_tags ~w(b i u span)

  @placeholder_re ~r/⟦(\d+)⟧/

  @doc """
  Extract translatable blocks from an HTML string.

  Each block is:

    * `%{type: :block, tag, attrs, text, placeholders}` — translatable unit;
      `text` carries `⟦n⟧` tokens, `placeholders` maps `n` → original inline
      markup
    * `%{type: :text, text}` — top-level bare text
    * `%{type: :raw, tag, attrs, text}` — `pre`/`code`, never translated

  Returns `{:ok, blocks}` or `{:error, term()}` for unparseable input.
  """
  @spec extract_blocks(String.t()) :: {:ok, [map()]} | {:error, term()}
  def extract_blocks(html) when is_binary(html) do
    with {:ok, tree} <- Floki.parse_document(html) do
      {blocks, _ph} = walk_nodes(tree, [], 0)
      {:ok, Enum.reverse(blocks)}
    end
  end

  def extract_blocks(_), do: {:error, :invalid_input}

  @doc """
  Reassemble one translated block: validate and restore placeholders, wrap in
  the original tag.

  `translated_text` must contain exactly the block's `⟦n⟧` tokens (all of
  them, no extras — order may change). Returns `{:ok, html}` or
  `{:error, :placeholder_mismatch}`.
  """
  @spec render_block(String.t(), map()) :: {:ok, String.t()} | {:error, :placeholder_mismatch}
  def render_block(translated_text, %{type: :text}) when is_binary(translated_text) do
    {:ok, translated_text}
  end

  def render_block(_translated_text, %{type: :raw, text: raw}) do
    {:ok, raw}
  end

  def render_block(translated_text, %{type: :block, tag: tag, attrs: attrs, placeholders: phs}) do
    with :ok <- validate_placeholders(translated_text, phs) do
      html = replace_placeholders(translated_text, phs)
      {:ok, "<#{tag}#{render_attrs(attrs)}>" <> html <> "</#{tag}>"}
    end
  end

  @doc """
  Strip HTML to plain text (degraded fallback for failed placeholder
  validation or unparseable input).
  """
  @spec to_plain_text(String.t()) :: String.t()
  def to_plain_text(html) when is_binary(html) do
    html
    |> Floki.parse_document!()
    |> Floki.text()
    |> String.trim()
  rescue
    _ -> String.trim(html)
  end

  # —— block extraction ——

  defp walk_nodes(nodes, acc, ph) when is_list(nodes) do
    Enum.reduce(nodes, {acc, ph}, fn node, {acc, ph} -> walk_nodes(node, acc, ph) end)
  end

  defp walk_nodes(text, acc, ph) when is_binary(text) do
    trimmed = String.trim(text)

    if trimmed == "" do
      {acc, ph}
    else
      {[%{type: :text, text: trimmed, placeholders: %{}} | acc], ph}
    end
  end

  defp walk_nodes({tag, attrs, children} = node, acc, ph) when is_binary(tag) do
    cond do
      tag in @raw_tags ->
        block = %{
          type: :raw,
          tag: tag,
          attrs: attrs,
          text: Floki.raw_html(node),
          placeholders: %{}
        }

        {[block | acc], ph}

      block_level?(tag, children) ->
        {text, phs, ph} = extract_inline(children, ph)
        block = %{type: :block, tag: tag, attrs: attrs, text: text, placeholders: phs}
        {[block | acc], ph}

      true ->
        # container: recurse into children
        walk_nodes(children, acc, ph)
    end
  end

  defp walk_nodes(_, acc, ph), do: {acc, ph}

  defp block_level?(tag, children) do
    cond do
      tag in @block_tags -> true
      tag in @container_tags -> not Enum.any?(children, &child_is_block?/1)
      true -> false
    end
  end

  defp child_is_block?({child_tag, _, _}) when is_binary(child_tag),
    do: child_tag in @block_tags or child_tag in @container_tags or child_tag in @raw_tags

  defp child_is_block?(_), do: false

  # —— inline handling ——

  defp extract_inline(nodes, ph) do
    Enum.reduce(nodes, {"", %{}, ph}, fn node, {text, phs, ph} ->
      case node do
        raw when is_binary(raw) ->
          {text <> raw, phs, ph}

        {tag, _attrs, _children} = el when is_binary(tag) ->
          cond do
            tag in @placeholder_tags ->
              {text <> "⟦#{ph}⟧", Map.put(phs, Integer.to_string(ph), Floki.raw_html(el)), ph + 1}

            tag in @unwrap_tags ->
              # style-only: unwrap so inner text is translated in-context.
              # Floki drops whitespace-only text nodes between elements, so
              # re-insert a single space when the join would otherwise merge
              # two words.
              {inner, inner_phs, ph} = extract_inline(elem(el, 2), ph)

              separator =
                if inner != "" and text != "" and not String.ends_with?(text, " "),
                  do: " ",
                  else: ""

              {text <> separator <> inner, Map.merge(phs, inner_phs), ph}

            true ->
              # unknown/odd element inside a block: unwrap recursively
              {inner, inner_phs, ph} = extract_inline(elem(el, 2), ph)
              {text <> inner, Map.merge(phs, inner_phs), ph}
          end

        _ ->
          {text, phs, ph}
      end
    end)
  end

  # —— reassembly ——

  defp validate_placeholders(text, phs) do
    found =
      text
      |> then(&Regex.scan(@placeholder_re, &1))
      |> Enum.map(fn [_, n] -> n end)
      |> Enum.sort()

    expected = phs |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort()

    if found == expected do
      :ok
    else
      {:error, :placeholder_mismatch}
    end
  end

  defp replace_placeholders(text, phs) do
    Regex.replace(@placeholder_re, text, fn _, n ->
      Map.get(phs, n, "⟦#{n}⟧")
    end)
  end

  defp render_attrs(attrs) do
    Enum.map(attrs, fn {name, value} -> ~s( #{name}="#{escape_attr(value)}") end) |> Enum.join()
  end

  defp escape_attr(value) do
    value |> to_string() |> String.replace("\"", "&quot;")
  end
end
