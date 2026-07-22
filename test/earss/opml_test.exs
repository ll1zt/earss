defmodule Earss.OPMLTest do
  use Earss.DataCase

  alias Earss.Reader
  alias Earss.Reader.OPML

  setup do
    {:ok, user} = Reader.create_user("opml_#{System.unique_integer([:positive])}", "secret")
    %{user: user}
  end

  test "parse sample opml" do
    xml = File.read!(Path.join([File.cwd!(), "test/fixtures/opml/sample.opml"]))
    assert {:ok, items} = OPML.parse(xml)
    assert length(items) == 3
    assert Enum.any?(items, &(&1.link == "https://example.com/rss.xml" and &1.category == "News"))
    assert Enum.any?(items, &(&1.link == "https://example.com/bare.xml" and is_nil(&1.category)))
  end

  test "import and export round-trip", %{user: user} do
    xml = File.read!(Path.join([File.cwd!(), "test/fixtures/opml/sample.opml"]))

    assert {:ok, stats} = Reader.import_opml(user, xml, refresh: false)
    assert stats.imported == 3
    assert stats.skipped == 0

    # second import skips duplicates
    assert {:ok, stats2} = Reader.import_opml(user, xml, refresh: false)
    assert stats2.imported == 0
    assert stats2.skipped == 3

    assert {:ok, out} = Reader.export_opml(user)
    assert out =~ "xmlUrl="
    assert out =~ "https://example.com/rss.xml"
    assert out =~ "News"
  end
end
