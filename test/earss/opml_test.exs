defmodule Earss.OPMLTest do
  use Earss.DataCase

  alias Earss.Reader
  alias Earss.Reader.OPML

  test "parse sample opml" do
    xml = File.read!(Path.join([File.cwd!(), "test/fixtures/opml/sample.opml"]))
    assert {:ok, items} = OPML.parse(xml)
    assert length(items) == 3
    assert Enum.any?(items, &(&1.link == "https://example.com/rss.xml" and &1.category == "News"))
    assert Enum.any?(items, &(&1.link == "https://example.com/bare.xml" and is_nil(&1.category)))
  end

  test "import and export round-trip" do
    xml = File.read!(Path.join([File.cwd!(), "test/fixtures/opml/sample.opml"]))

    assert {:ok, stats} = Reader.import_opml(xml, refresh: false)
    assert stats.imported == 3
    assert stats.skipped == 0

    # second import skips duplicates
    assert {:ok, stats2} = Reader.import_opml(xml, refresh: false)
    assert stats2.imported == 0
    assert stats2.skipped == 3

    assert {:ok, out} = Reader.export_opml()
    assert out =~ "xmlUrl="
    assert out =~ "https://example.com/rss.xml"
    assert out =~ "News"
    assert out =~ ~s(type="rss")
  end

  test "parse and export earss:// plugin outlines" do
    xml = """
    <?xml version="1.0"?>
    <opml version="2.0">
      <body>
        <outline type="earss" text="TG" xmlUrl="earss://telegram/channel/demo"/>
        <outline type="rss" text="Web" xmlUrl="https://example.com/a.xml"/>
      </body>
    </opml>
    """

    assert {:ok, items} = OPML.parse(xml)
    assert Enum.any?(items, &(&1.link == "earss://telegram/channel/demo"))
    assert Enum.any?(items, &(&1.link == "https://example.com/a.xml"))

    out =
      OPML.export([
        %{title: "TG", link: "earss://telegram/channel/demo", category: nil},
        %{title: "Web", link: "https://example.com/a.xml", category: nil}
      ])

    assert out =~ ~s(type="earss")
    assert out =~ ~s(xmlUrl="earss://telegram/channel/demo")
    assert out =~ ~s(type="rss")
  end
end
