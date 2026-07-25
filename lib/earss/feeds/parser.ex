defmodule Earss.Feeds.Parser do
  @moduledoc """
  Feed document parser.

  Detects JSON Feed, Atom, or RSS and returns normalized maps suitable for
  `Earss.Feeds` upserts.
  """

  import SweetXml

  @type entry_map :: %{
          required(:link) => String.t(),
          required(:guid) => String.t(),
          optional(:title) => String.t() | nil,
          optional(:author) => String.t() | nil,
          optional(:summary) => String.t() | nil,
          optional(:content) => String.t() | nil,
          optional(:published_at) => DateTime.t() | nil
        }

  @type parse_result ::
          {:ok,
           %{
             feed: %{
               optional(:title) => String.t() | nil,
               optional(:description) => String.t() | nil,
               optional(:site_url) => String.t() | nil
             },
             entries: [entry_map()],
             feed_type: String.t()
           }}
          | {:error, {:parse, term()}}

  @doc """
  Parse a feed `body`. Optional `content_type` hint helps detection.
  """
  @spec parse(binary(), String.t() | nil) :: parse_result()
  def parse(body, content_type \\ nil) when is_binary(body) do
    trimmed =
      body
      |> strip_bom()
      |> String.trim()

    cond do
      trimmed == "" ->
        {:error, {:parse, :empty_body}}

      json_feed?(trimmed, content_type) ->
        parse_json_feed(trimmed)

      true ->
        parse_xml_feed(trimmed)
    end
  rescue
    e -> {:error, {:parse, e}}
  end

  defp strip_bom(<<"\uFEFF", rest::binary>>), do: rest
  defp strip_bom(bin), do: bin

  defp json_feed?(body, content_type) do
    type = content_type || ""

    String.contains?(type, "json") or
      String.starts_with?(body, "{") or
      String.starts_with?(body, "\uFEFF{")
  end

  defp parse_json_feed(body) do
    case Jason.decode(body) do
      {:ok, %{"items" => items} = data} when is_list(items) ->
        feed = %{
          title: data["title"],
          description: data["description"],
          site_url: data["home_page_url"] || data["home_page"]
        }

        entries =
          items
          |> Enum.map(&json_item_to_entry/1)
          |> Enum.reject(&is_nil/1)

        {:ok, %{feed: feed, entries: entries, feed_type: "json"}}

      {:ok, _} ->
        {:error, {:parse, :invalid_json_feed}}

      {:error, reason} ->
        {:error, {:parse, reason}}
    end
  end

  defp json_item_to_entry(item) when is_map(item) do
    link = item["url"] || item["external_url"]
    guid = item["id"] || link

    if blank?(link) and blank?(guid) do
      nil
    else
      link = if blank?(link), do: to_string(guid), else: to_string(link)
      guid = if blank?(guid), do: link, else: to_string(guid)

      %{
        link: link,
        guid: guid,
        title: item["title"],
        author: json_author(item),
        summary: item["summary"],
        content: item["content_html"] || item["content_text"],
        published_at: parse_datetime(item["date_published"] || item["date_modified"])
      }
    end
  end

  defp json_item_to_entry(_), do: nil

  defp json_author(%{"authors" => [%{"name" => name} | _]}) when is_binary(name), do: name
  defp json_author(%{"author" => %{"name" => name}}) when is_binary(name), do: name
  defp json_author(%{"author" => name}) when is_binary(name), do: name
  defp json_author(_), do: nil

  defp parse_xml_feed(body) do
    case detect_xml_kind(body) do
      :atom -> parse_atom(body)
      :rss -> parse_rss(body)
      :unknown -> {:error, {:parse, :unknown_feed_format}}
    end
  end

  defp detect_xml_kind(body) do
    lower = String.downcase(body)

    # Prefer explicit RSS root. Many RSS 2.0 feeds declare the Atom xmlns and may
    # contain tags like <feedId>, which previously made us mis-detect as Atom and
    # parse zero entries (then content-hash short-circuit kept the feed empty).
    cond do
      String.contains?(lower, "<rss") or String.contains?(lower, "<rdf:rdf") ->
        :rss

      atom_feed_element?(lower) ->
        :atom

      String.contains?(lower, "<channel") ->
        :rss

      true ->
        :unknown
    end
  end

  # Match a real Atom <feed ...> root/element, not substrings like <feedId>.
  defp atom_feed_element?(lower) do
    Regex.match?(~r/<feed(\s|>|\/)/, lower) or
      Regex.match?(~r/<(?:[a-z0-9_]+:)?feed(\s|>|\/)/, lower)
  end

  defp parse_atom(body) do
    doc = SweetXml.parse(body, quiet: true)

    feed = %{
      title: text(doc, ~x"//*[local-name()='feed']/*[local-name()='title']/text()"s),
      description: text(doc, ~x"//*[local-name()='feed']/*[local-name()='subtitle']/text()"s),
      site_url: atom_feed_link(doc)
    }

    entries =
      doc
      |> xpath(~x"//*[local-name()='feed']/*[local-name()='entry']"l)
      |> Enum.map(&atom_entry/1)
      |> Enum.reject(&is_nil/1)

    {:ok, %{feed: feed, entries: entries, feed_type: "atom"}}
  end

  defp atom_feed_link(doc) do
    links = xpath(doc, ~x"//*[local-name()='feed']/*[local-name()='link']"l)

    Enum.find_value(links, fn link ->
      rel = xpath(link, ~x"./@rel"s) || ""
      href = xpath(link, ~x"./@href"s) || ""

      if href != "" and rel in ["", "alternate"] do
        href
      else
        nil
      end
    end) || text(doc, ~x"//*[local-name()='feed']/*[local-name()='link'][1]/@href"s)
  end

  defp atom_entry(entry_node) do
    link =
      entry_node
      |> xpath(~x"./*[local-name()='link']"l)
      |> Enum.find_value(fn link ->
        rel = xpath(link, ~x"./@rel"s) || ""
        href = xpath(link, ~x"./@href"s) || ""

        if href != "" and rel in ["", "alternate"] do
          href
        else
          nil
        end
      end)

    # Some Atom feeds omit alternate and only have rel=self or bare href later
    link =
      link ||
        entry_node
        |> xpath(~x"./*[local-name()='link']/@href"s)
        |> empty_to_nil()

    guid = text(entry_node, ~x"./*[local-name()='id']/text()"s)
    link = link || guid

    if blank?(link) do
      nil
    else
      published =
        text(entry_node, ~x"./*[local-name()='published']/text()"s) ||
          text(entry_node, ~x"./*[local-name()='updated']/text()"s)

      %{
        link: link,
        guid: guid || link,
        title:
          text(entry_node, ~x"./*[local-name()='title']/text()"s) ||
            text(entry_node, ~x"./*[local-name()='title']"s),
        author: text(entry_node, ~x"./*[local-name()='author']/*[local-name()='name']/text()"s),
        summary:
          text(entry_node, ~x"./*[local-name()='summary']/text()"s) ||
            text(entry_node, ~x"./*[local-name()='summary']"s),
        content:
          text(entry_node, ~x"./*[local-name()='content']/text()"s) ||
            text(entry_node, ~x"./*[local-name()='content']"s),
        published_at: parse_datetime(published)
      }
    end
  end

  defp parse_rss(body) do
    doc = SweetXml.parse(body, quiet: true)

    feed = %{
      title: text(doc, ~x"//channel/title/text()"s),
      description: text(doc, ~x"//channel/description/text()"s),
      site_url: text(doc, ~x"//channel/link/text()"s)
    }

    entries =
      doc
      |> xpath(~x"//channel/item"l)
      |> Enum.map(&rss_item/1)
      |> Enum.reject(&is_nil/1)

    {:ok, %{feed: feed, entries: entries, feed_type: "rss"}}
  end

  defp rss_item(item) do
    # Prefer explicit link; some feeds only put URL in guid or atom:link
    link =
      text(item, ~x"./link/text()"s) ||
        text(item, ~x"./*[local-name()='link']/@href"s) ||
        text(item, ~x"./guid/text()"s)

    guid = text(item, ~x"./guid/text()"s) || link

    if blank?(link) do
      nil
    else
      description = text(item, ~x"./description/text()"s) || text(item, ~x"./description"s)

      content =
        text(item, ~x"./*[local-name()='encoded']/text()"s) ||
          text(item, ~x"./*[local-name()='encoded']"s) ||
          description

      %{
        link: link,
        guid: guid || link,
        title: text(item, ~x"./title/text()"s) || text(item, ~x"./title"s),
        author:
          text(item, ~x"./author/text()"s) ||
            text(item, ~x"./*[local-name()='creator']/text()"s),
        summary: description,
        content: content,
        published_at:
          parse_datetime(
            text(item, ~x"./pubDate/text()"s) ||
              text(item, ~x"./*[local-name()='date']/text()"s) ||
              text(item, ~x"./*[local-name()='published']/text()"s)
          )
      }
    end
  end

  defp text(node, spec) do
    case xpath(node, spec) do
      nil ->
        nil

      "" ->
        nil

      value when is_binary(value) ->
        value |> decode_basic_entities() |> empty_to_nil()

      value ->
        value |> to_string() |> decode_basic_entities() |> empty_to_nil()
    end
  end

  defp decode_basic_entities(nil), do: nil

  defp decode_basic_entities(str) when is_binary(str) do
    str
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&apos;", "'")
    |> String.replace("&amp;", "&")
  end

  defp parse_datetime(nil), do: nil
  defp parse_datetime(""), do: nil

  defp parse_datetime(value) when is_binary(value) do
    value = String.trim(value)

    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> DateTime.truncate(dt, :second)
      {:error, _} -> parse_rfc2822(value)
    end
  end

  defp parse_rfc2822(value) do
    case Earss.Feeds.Parser.RFC2822.parse(value) do
      {:ok, dt} -> dt
      _ -> nil
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(v) when is_binary(v), do: String.trim(v) == ""
  defp blank?(_), do: false

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(v), do: v
end

defmodule Earss.Feeds.Parser.RFC2822 do
  @moduledoc false

  @months %{
    "Jan" => 1,
    "Feb" => 2,
    "Mar" => 3,
    "Apr" => 4,
    "May" => 5,
    "Jun" => 6,
    "Jul" => 7,
    "Aug" => 8,
    "Sep" => 9,
    "Oct" => 10,
    "Nov" => 11,
    "Dec" => 12
  }

  def parse(value) do
    regex =
      ~r/^(?:[A-Za-z]{3},\s*)?(\d{1,2})\s+([A-Za-z]{3})\s+(\d{4})\s+(\d{2}):(\d{2})(?::(\d{2}))?\s+(.+)$/

    case Regex.run(regex, String.trim(value)) do
      [_, day, mon, year, hour, min, sec, tz] ->
        with month when is_integer(month) <- Map.get(@months, mon),
             {:ok, date} <- Date.new(String.to_integer(year), month, String.to_integer(day)),
             {:ok, time} <-
               Time.new(
                 String.to_integer(hour),
                 String.to_integer(min),
                 String.to_integer(sec || "0")
               ),
             {:ok, naive} <- NaiveDateTime.new(date, time),
             {:ok, dt} <- from_naive_utc(naive, tz) do
          {:ok, DateTime.truncate(dt, :second)}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp from_naive_utc(naive, tz) do
    tz = String.trim(tz)

    cond do
      tz in ["GMT", "UTC", "Z", "UT"] ->
        DateTime.from_naive(naive, "Etc/UTC")

      Regex.match?(~r/^[+-]\d{4}$/, tz) ->
        sign = if String.starts_with?(tz, "-"), do: -1, else: 1
        {hh, _} = Integer.parse(String.slice(tz, 1, 2))
        {mm, _} = Integer.parse(String.slice(tz, 3, 2))
        offset = sign * (hh * 3600 + mm * 60)

        dt =
          naive
          |> DateTime.from_naive!("Etc/UTC")
          |> DateTime.add(-offset, :second)

        {:ok, dt}

      true ->
        DateTime.from_naive(naive, "Etc/UTC")
    end
  end
end
