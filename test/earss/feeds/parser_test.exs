defmodule Earss.Feeds.ParserTest do
  use ExUnit.Case, async: true

  alias Earss.Feeds.Parser

  defp fixture(name) do
    Path.join([File.cwd!(), "test/fixtures/feeds", name])
    |> File.read!()
  end

  test "parses RSS 2.0" do
    assert {:ok, %{feed_type: "rss", feed: feed, entries: entries}} =
             Parser.parse(fixture("sample.rss.xml"))

    assert feed.title == "Example RSS"
    assert feed.site_url == "https://example.com/"
    assert length(entries) == 2

    first = Enum.find(entries, &(&1.guid == "https://example.com/posts/1"))
    assert first.title == "First Post"
    assert first.link == "https://example.com/posts/1"
    assert %DateTime{} = first.published_at
  end

  test "parses Atom" do
    assert {:ok, %{feed_type: "atom", feed: feed, entries: entries}} =
             Parser.parse(fixture("sample.atom.xml"))

    assert feed.title == "Example Atom"
    assert feed.site_url == "https://example.com/"
    assert length(entries) == 2

    one = Enum.find(entries, &(&1.guid == "urn:uuid:atom-1"))
    assert one.title == "Atom One"
    assert one.author == "Alice"
    assert one.link == "https://example.com/atom/1"
  end

  test "parses JSON Feed" do
    assert {:ok, %{feed_type: "json", feed: feed, entries: entries}} =
             Parser.parse(fixture("sample.json"))

    assert feed.title == "Example JSON Feed"
    assert feed.site_url == "https://example.com/"
    assert length(entries) == 2

    one = Enum.find(entries, &(&1.guid == "json-1"))
    assert one.title == "JSON One"
    assert one.author == "Bob"
  end

  test "rejects empty body" do
    assert {:error, {:parse, :empty_body}} = Parser.parse("   ")
  end

  test "parses messy real-world-ish RSS" do
    body = File.read!(Path.join([File.cwd!(), "test/fixtures/feeds/messy.rss.xml"]))
    # UTF-8 BOM prefix
    assert {:ok, %{feed_type: "rss", entries: entries}} = Parser.parse(<<"\uFEFF", body::binary>>)
    assert length(entries) == 2

    entity = Enum.find(entries, &(&1.guid == "https://example.com/posts/entity"))
    assert entity.title == "Entity & Title"
    assert entity.link == "https://example.com/posts/entity"
    assert entity.content =~ "Full content"
    assert %DateTime{} = entity.published_at

    atom_link = Enum.find(entries, &(&1.link == "https://example.com/posts/atom-link"))
    assert atom_link.title == "Atom-style link"
  end

  test "RSS with Atom xmlns and <feedId> is not mis-detected as Atom" do
    assert {:ok, %{feed_type: "rss", feed: feed, entries: entries}} =
             Parser.parse(fixture("rss_with_atom_ns.xml"))

    assert feed.title == "SkyWT-like"
    assert length(entries) == 2
    assert Enum.any?(entries, &(&1.title == "Hello"))
  end

  test "Atom empty/html summary does not crash (xmerl xmlElement)" do
    assert {:ok, %{feed_type: "atom", entries: entries}} =
             Parser.parse(fixture("empty_html_summary.atom.xml"))

    assert length(entries) == 3

    a = Enum.find(entries, &(&1.guid == "urn:uuid:empty-a"))
    assert a.summary == "Hello summary"
    assert a.content == "Body A"

    b = Enum.find(entries, &(&1.guid == "urn:uuid:empty-b"))
    assert b.summary == nil
    assert b.content == "<p>Body B</p>"

    c = Enum.find(entries, &(&1.guid == "urn:uuid:empty-c"))
    assert c.summary == nil
    assert c.title == "Self-closing summary"
  end

  test "RSS CDATA description/content:encoded and empty description" do
    assert {:ok, %{feed_type: "rss", entries: entries}} =
             Parser.parse(fixture("cdata_description.rss.xml"))

    assert length(entries) == 2

    cdata = Enum.find(entries, &(&1.guid == "http://example.com/?p=1"))
    assert cdata.author == "Author"
    assert cdata.summary =~ "Short blurb"
    assert cdata.content =~ "Full body"
    assert %DateTime{} = cdata.published_at

    empty = Enum.find(entries, &(&1.link == "https://example.com/posts/empty-desc"))
    assert empty.summary == nil
    assert empty.content == "<p>Only full content</p>"
  end
end
