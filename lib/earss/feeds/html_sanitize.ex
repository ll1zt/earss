defmodule Earss.Feeds.HTMLSanitize do
  @moduledoc """
  Best-effort HTML sanitization for entry `content` / `summary` before storage.

  Goals (Phase 7 hardening):

    * Strip high-risk tags (`script`, `iframe`, …)
    * Drop event-handler attributes (`onclick`, …)
    * Neutralize dangerous URL schemes in `href` / `src` / etc.

  This is a **deny-list** scrubber, not a full HTML allow-list policy.
  Disable with `config :earss, :html_sanitize, enabled: false`.
  """

  @drop_tags ~w(
    script style iframe object embed applet
    link meta base form
    frame frameset
    svg math
  )

  @url_attrs ~w(href src xlink:href formaction action poster data)

  @doc """
  Sanitize an HTML fragment. Returns `nil` for `nil`; non-binaries unchanged.
  """
  @spec sanitize(term()) :: term()
  def sanitize(nil), do: nil

  def sanitize(html) when is_binary(html) do
    if enabled?() do
      do_sanitize(html)
    else
      html
    end
  end

  def sanitize(other), do: other

  defp enabled? do
    Application.get_env(:earss, :html_sanitize, [])
    |> Keyword.get(:enabled, true)
  end

  defp do_sanitize(html) do
    case Floki.parse_fragment(html) do
      {:ok, tree} ->
        tree
        |> drop_tags()
        |> scrub_tree()
        |> Floki.raw_html()

      {:error, _} ->
        # Unparseable markup: strip angle-bracket runs as a last resort
        Regex.replace(~r/<[^>]*>/, html, "")
    end
  end

  defp drop_tags(tree) do
    Enum.reduce(@drop_tags, tree, fn tag, acc -> Floki.filter_out(acc, tag) end)
  end

  defp scrub_tree(nodes) when is_list(nodes), do: Enum.map(nodes, &scrub_node/1)

  defp scrub_node({tag, attrs, children}) when is_list(attrs) and is_list(children) do
    {tag, scrub_attrs(attrs), scrub_tree(children)}
  end

  defp scrub_node(other), do: other

  defp scrub_attrs(attrs) do
    Enum.reject(attrs, fn {name, value} ->
      n = name |> to_string() |> String.downcase()

      String.starts_with?(n, "on") or
        n in ["srcdoc"] or
        (n in @url_attrs and dangerous_url?(value))
    end)
  end

  defp dangerous_url?(value) do
    value
    |> to_string()
    |> decode_entities()
    # Browsers ignore control characters in URLs (java\tscript: is valid
    # obfuscation); strip them before the scheme check.
    |> String.replace(~r/[\x00-\x20]/, "")
    |> String.trim()
    |> String.downcase()
    |> then(fn v ->
      String.starts_with?(v, "javascript:") or
        String.starts_with?(v, "vbscript:") or
        String.starts_with?(v, "data:text/html")
    end)
  end

  # Decode HTML entities before URL-scheme checks — the classic
  # `javascript&#58;alert(1)` bypass. Numeric refs are decoded to real
  # code points; a small map covers the named refs useful for scheme
  # obfuscation (unknown named refs stay untouched).
  @named_entities %{
    "colon" => ":",
    "tab" => "\t",
    "newline" => "\n",
    "sol" => "/",
    "lpar" => "(",
    "rpar" => ")",
    "num" => "#"
  }

  defp decode_entities(value) do
    value
    |> then(
      &Regex.replace(~r/&#x([0-9a-fA-F]+);/, &1, fn _, hex ->
        codepoint(String.to_integer(hex, 16))
      end)
    )
    |> then(
      &Regex.replace(~r/&#([0-9]+);/, &1, fn _, dec -> codepoint(String.to_integer(dec)) end)
    )
    |> then(fn decoded ->
      Regex.replace(~r/&([a-zA-Z]+);/, decoded, fn _, name ->
        Map.get(@named_entities, String.downcase(name), "&" <> name <> ";")
      end)
    end)
  end

  defp codepoint(cp) when cp >= 1 and cp <= 0x10FFFF do
    <<cp::utf8>>
  rescue
    ArgumentError -> ""
  end

  defp codepoint(_cp), do: ""
end
