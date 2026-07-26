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
      title: text(doc, ~x"string(//*[local-name()='feed']/*[local-name()='title'])"s),
      description: text(doc, ~x"string(//*[local-name()='feed']/*[local-name()='subtitle'])"s),
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
      rel = attr(link, "rel") || ""
      href = attr(link, "href") || ""

      if href != "" and rel in ["", "alternate"] do
        href
      else
        nil
      end
    end) || text(doc, ~x"string(//*[local-name()='feed']/*[local-name()='link'][1]/@href)"s)
  end

  defp atom_entry(entry_node) do
    link =
      entry_node
      |> xpath(~x"./*[local-name()='link']"l)
      |> Enum.find_value(fn link ->
        rel = attr(link, "rel") || ""
        href = attr(link, "href") || ""

        if href != "" and rel in ["", "alternate"] do
          href
        else
          nil
        end
      end)

    # Some Atom feeds omit alternate and only have rel=self or bare href later
    link = link || text(entry_node, ~x"string(./*[local-name()='link']/@href)"s)

    guid = text(entry_node, ~x"string(./*[local-name()='id'])"s)
    link = link || guid

    if blank?(link) do
      nil
    else
      published =
        text(entry_node, ~x"string(./*[local-name()='published'])"s) ||
          text(entry_node, ~x"string(./*[local-name()='updated'])"s)

      %{
        link: link,
        guid: guid || link,
        title: text(entry_node, ~x"string(./*[local-name()='title'])"s),
        author: text(entry_node, ~x"string(./*[local-name()='author']/*[local-name()='name'])"s),
        # Use XPath string() so empty <summary/> / HTML-typed nodes never surface
        # as raw xmerl xmlElement tuples (String.Chars would crash).
        summary: text(entry_node, ~x"string(./*[local-name()='summary'])"s),
        content: text(entry_node, ~x"string(./*[local-name()='content'])"s),
        published_at: parse_datetime(published)
      }
    end
  end

  defp parse_rss(body) do
    doc = SweetXml.parse(body, quiet: true)

    feed = %{
      title: text(doc, ~x"string(//channel/title)"s),
      description: text(doc, ~x"string(//channel/description)"s),
      site_url: text(doc, ~x"string(//channel/link)"s)
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
      text(item, ~x"string(./link)"s) ||
        text(item, ~x"string(./*[local-name()='link']/@href)"s) ||
        text(item, ~x"string(./guid)"s)

    guid = text(item, ~x"string(./guid)"s) || link

    if blank?(link) do
      nil
    else
      description = text(item, ~x"string(./description)"s)

      content =
        text(item, ~x"string(./*[local-name()='encoded'])"s) ||
          description

      %{
        link: link,
        guid: guid || link,
        title: text(item, ~x"string(./title)"s),
        author:
          text(item, ~x"string(./author)"s) ||
            text(item, ~x"string(./*[local-name()='creator'])"s),
        summary: description,
        content: content,
        published_at:
          parse_datetime(
            text(item, ~x"string(./pubDate)"s) ||
              text(item, ~x"string(./*[local-name()='date'])"s) ||
              text(item, ~x"string(./*[local-name()='published'])"s)
          )
      }
    end
  end

  defp attr(node, name) when is_binary(name) do
    text(node, ~x"string(./@#{name})"s)
  end

  # Safe text extraction. Prefer XPath `string(...)` specs so element nodes
  # (including empty tags and CDATA-only children) become binaries. Never call
  # Kernel.to_string/1 on xmerl records — they are tuples without String.Chars.
  defp text(node, spec) do
    case safe_xpath(node, spec) do
      nil ->
        nil

      "" ->
        nil

      value when is_binary(value) ->
        value |> decode_basic_entities() |> empty_to_nil()

      value when is_list(value) ->
        cond do
          value == [] ->
            nil

          Enum.all?(value, &is_integer/1) ->
            value |> List.to_string() |> decode_basic_entities() |> empty_to_nil()

          true ->
            value
            |> Enum.map(&node_to_text/1)
            |> Enum.reject(&is_nil/1)
            |> Enum.join()
            |> decode_basic_entities()
            |> empty_to_nil()
        end

      value ->
        value |> node_to_text() |> decode_basic_entities() |> empty_to_nil()
    end
  end

  defp safe_xpath(node, spec) do
    xpath(node, spec)
  rescue
    Protocol.UndefinedError -> nil
    ArgumentError -> nil
  end

  defp node_to_text(value) when is_binary(value), do: value
  defp node_to_text(value) when is_atom(value), do: Atom.to_string(value)
  defp node_to_text(value) when is_integer(value), do: Integer.to_string(value)

  defp node_to_text(value) when is_list(value) do
    if value != [] and Enum.all?(value, &is_integer/1) do
      List.to_string(value)
    else
      value
      |> Enum.map(&node_to_text/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.join()
    end
  end

  # xmerl xmlText | xmlElement | xmlAttribute tuples — extract character data only.
  defp node_to_text({:xmlText, _, _, _, text, _}) do
    node_to_text(text)
  end

  defp node_to_text({:xmlElement, _, _, _, _, _, _, _, children, _, _, _}) do
    node_to_text(children)
  end

  defp node_to_text({:xmlAttribute, _, _, _, _, _, _, _, value, _}) do
    node_to_text(value)
  end

  defp node_to_text(_), do: nil

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
