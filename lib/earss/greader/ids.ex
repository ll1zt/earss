defmodule Earss.GReader.Ids do
  @moduledoc false

  alias Earss.Feeds.Feed

  # FreshRSS / NetNewsWire use numeric feed stream ids (`feed/42`), not the feed URL.
  def feed_stream_id(%Feed{id: id}), do: "feed/#{id}"

  def label_stream_id(name), do: "user/-/label/#{name}"

  def item_hex_id(id) when is_integer(id) do
    id |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(16, "0")
  end

  def item_atom_id(id) when is_integer(id) do
    "tag:google.com,2005:reader/item/#{item_hex_id(id)}"
  end

  def parse_item_id(nil), do: nil
  def parse_item_id(id) when is_integer(id), do: id

  def parse_item_id(str) when is_binary(str) do
    str = String.trim(str)

    cond do
      # NetNewsWire posts contents/edit-tag as:
      #   i=tag:google.com,2005:reader/item/<unpadded-hex>
      # e.g. entry 51 → ".../item/33". This MUST be parsed as hex, not decimal.
      String.contains?(str, "/item/") ->
        hex = str |> String.split("/item/") |> List.last() |> String.trim()
        parse_hex(hex)

      true ->
        parse_hex_or_dec(str)
    end
  end

  def parse_hex(str) when is_binary(str) do
    if String.match?(str, ~r/^[0-9a-fA-F]+$/) do
      case Integer.parse(str, 16) do
        {i, _} -> i
        :error -> nil
      end
    else
      nil
    end
  end

  def parse_hex_or_dec(str) do
    # Bare ids: hex if it has a-f or is zero-padded/long (GReader style),
    # otherwise decimal (itemRefs use decimal strings like "51").
    cond do
      String.match?(str, ~r/^[0-9a-fA-F]+$/) and
          (String.match?(str, ~r/[a-fA-F]/) or String.starts_with?(str, "0") or
             String.length(str) >= 8) ->
        parse_hex(str)

      match?({_, _}, Integer.parse(str)) ->
        {i, _} = Integer.parse(str)
        i

      String.match?(str, ~r/^[0-9a-fA-F]+$/) ->
        parse_hex(str)

      true ->
        nil
    end
  end

  def sortid(n) when is_integer(n) do
    n
    |> Integer.to_string(16)
    |> String.upcase()
    |> String.pad_leading(8, "0")
  end

  def parse_continuation(nil), do: nil
  def parse_continuation(""), do: nil

  def parse_continuation(s) when is_binary(s) do
    case Integer.parse(s) do
      {i, _} -> i
      :error -> nil
    end
  end

  def parse_continuation(i) when is_integer(i), do: i
  def parse_continuation(_), do: nil

  def label_from_stream(stream_id) do
    stream_id
    |> String.split("/label/")
    |> List.last()
    |> URI.decode()
  end

  def normalize_stream_id(nil), do: nil

  def normalize_stream_id(stream_id) when is_binary(stream_id) do
    stream_id
    |> URI.decode()
    |> String.trim()
    |> String.trim_leading("/")
    |> String.replace(~r{^user/\d+/}, "user/-/")
    |> expand_short_stream_id()
  end

  def normalize_stream_id(other), do: other

  # FreshRSS examples and some clients use bare suffixes:
  #   stream/contents/reading-list, stream/contents/starred
  def expand_short_stream_id("reading-list"),
    do: "user/-/state/com.google/reading-list"

  def expand_short_stream_id("starred"), do: "user/-/state/com.google/starred"
  def expand_short_stream_id("read"), do: "user/-/state/com.google/read"
  def expand_short_stream_id(other), do: other

  def reading_list_stream?(stream_id) do
    stream_id in [nil, "", "user/-/state/com.google/reading-list", "reading-list"]
  end

  def starred_stream?(stream_id),
    do: stream_id in ["user/-/state/com.google/starred", "starred"]

  def read_stream?(stream_id),
    do: stream_id in ["user/-/state/com.google/read", "read"]
end
