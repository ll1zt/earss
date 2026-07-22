defmodule Earss.Reader.OPML do
  @moduledoc """
  OPML 1.0/2.0 import and export for subscriptions.
  """

  import SweetXml

  @doc """
  Parse OPML XML into a list of feed outlines.

  Returns `{:ok, [%{link: url, title: title | nil, category: name | nil}]}`
  or `{:error, reason}`.
  """
  @spec parse(binary()) ::
          {:ok, [%{link: String.t(), title: String.t() | nil, category: String.t() | nil}]}
          | {:error, term()}
  def parse(xml) when is_binary(xml) do
    xml = String.trim(xml)

    if xml == "" do
      {:error, :empty}
    else
      doc = SweetXml.parse(xml, quiet: true)
      outlines = xpath(doc, ~x"//outline"l)
      items = Enum.flat_map(outlines, &outline_to_items(&1, nil))
      {:ok, Enum.uniq_by(items, & &1.link)}
    end
  rescue
    e -> {:error, e}
  end

  @doc """
  Build OPML 2.0 XML for a list of subscription maps.

  Each item: `%{title: _, link: _, category: _ | nil}`.
  """
  @spec export([map()], String.t()) :: String.t()
  def export(items, title \\ "Earss Subscriptions") when is_list(items) do
    grouped =
      items
      |> Enum.group_by(fn i -> Map.get(i, :category) || Map.get(i, "category") end)

    body =
      grouped
      |> Enum.sort_by(fn {cat, _} -> cat || "" end)
      |> Enum.map(fn
        {nil, feeds} ->
          Enum.map(feeds, &feed_outline/1) |> Enum.join("\n")

        {cat, feeds} ->
          children = Enum.map(feeds, &feed_outline/1) |> Enum.join("\n")

          ~s(    <outline text="#{esc(cat)}" title="#{esc(cat)}">\n#{children}\n    </outline>)
      end)
      |> Enum.join("\n")

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <opml version="2.0">
      <head>
        <title>#{esc(title)}</title>
      </head>
      <body>
    #{body}
      </body>
    </opml>
    """
  end

  defp outline_to_items(node, parent_category) do
    xml_url = attr(node, "xmlUrl") || attr(node, "xmlurl")
    text = attr(node, "text") || attr(node, "title")
    children = xpath(node, ~x"./outline"l)

    cond do
      is_binary(xml_url) and String.trim(xml_url) != "" ->
        [
          %{
            link: String.trim(xml_url),
            title: empty_to_nil(text),
            category: parent_category
          }
        ]

      children != [] ->
        cat = empty_to_nil(text) || parent_category
        Enum.flat_map(children, &outline_to_items(&1, cat))

      true ->
        []
    end
  end

  defp feed_outline(item) do
    title =
      Map.get(item, :title) || Map.get(item, "title") || Map.get(item, :link) ||
        Map.get(item, "link")

    link = Map.get(item, :link) || Map.get(item, "link")
    html = Map.get(item, :site_url) || Map.get(item, "site_url")

    html_attr =
      if is_binary(html) and html != "" do
        ~s( htmlUrl="#{esc(html)}")
      else
        ""
      end

    ~s(    <outline type="rss" text="#{esc(title)}" title="#{esc(title)}" xmlUrl="#{esc(link)}"#{html_attr}/>)
  end

  defp attr(node, name) do
    case xpath(node, ~x"./@#{name}"s) do
      "" -> nil
      nil -> nil
      v -> v
    end
  end

  defp empty_to_nil(nil), do: nil
  defp empty_to_nil(""), do: nil
  defp empty_to_nil(v), do: v

  defp esc(nil), do: ""

  defp esc(str) when is_binary(str) do
    str
    |> String.replace("&", "&amp;")
    |> String.replace("\"", "&quot;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp esc(other), do: esc(to_string(other))
end
