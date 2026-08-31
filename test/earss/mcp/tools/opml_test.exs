defmodule Earss.MCP.Tools.OpmlTest do
  @moduledoc """
  Tests for OPML export/import, and for the destructive confirm flow as it
  behaves over the wire through Earss.MCP.Handler.

  Import previews the document without creating anything until
  `confirm: true` arrives; the already-subscribed case is skipped rather
  than duplicated, matching Reader.import_opml/2.
  """

  use Earss.DataCase, async: false

  alias Earss.Feeds
  alias Earss.MCP.Handler
  alias Earss.MCP.Tools.Opml
  alias Earss.Reader

  setup do
    {:ok, feed} =
      Feeds.create_feed(%{link: "https://example.com/mcp-opml.xml", title: "Opml Feed"})

    {:ok, _} = Reader.subscribe(%{feed_id: feed.id, refresh: false})
    %{feed: feed}
  end

  defp tool(name), do: Enum.find(Opml.tools(), &(&1.name == name))

  defp call(name, args \\ %{}), do: tool(name).handler.(args)

  defp call_via_handler(name, args) do
    {:ok, result, _state} = Handler.handle_call_tool(name, args, %{})
    result
  end

  defp opml_doc(links) do
    outlines = Enum.map_join(links, "\n", fn l -> ~s(    <outline type="rss" xmlUrl="#{l}"/>) end)

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <opml version="2.0">
      <body>
    #{outlines}
      </body>
    </opml>
    """
  end

  describe "opml_export/1" do
    test "returns an OPML document containing the subscription", %{feed: feed} do
      assert {:ok, result} = call("opml_export")

      assert is_binary(result.opml)
      assert result.opml =~ ~s(xmlUrl="#{feed.link}")
    end

    test "is read-only" do
      assert tool("opml_export").mutating == false
    end
  end

  describe "opml_import/1 — two-phase" do
    test "without confirm it previews and creates nothing" do
      doc = opml_doc(["https://example.com/imp-1.xml", "https://example.com/imp-2.xml"])

      report = call_via_handler("opml_import", %{"opml" => doc}) |> struct_content()

      assert report.executed == false
      assert report.requires_confirmation == true
      assert report.outlines == 2

      # Nothing was created.
      assert length(Feeds.list_all_feeds()) == 1
    end

    test "with confirm it imports and skips already-subscribed feeds", %{feed: feed} do
      doc =
        opml_doc([
          feed.link,
          "https://example.com/imp-new.xml"
        ])

      report =
        call_via_handler("opml_import", %{"opml" => doc, "confirm" => true}) |> struct_content()

      assert report.executed == true
      assert report.imported == 1
      assert report.skipped == 1

      assert Feeds.get_feed_by_link("https://example.com/imp-new.xml")
    end

    test "reports a parse error in the preview" do
      report = call_via_handler("opml_import", %{"opml" => "not xml at all"}) |> struct_content()

      assert report.affected == :none
      assert report[:parse_error]
    end

    test "is marked destructive; export is not" do
      assert tool("opml_import").destructive == true
      assert tool("opml_export").destructive == false
    end
  end

  # text_result puts the payload under "structuredContent" (string key), but
  # what sits there keeps its atom keys; normalise the access in one place.
  defp struct_content(result) do
    sc = result["structuredContent"] || result[:structuredContent]

    case sc do
      %{executed: _} = m -> m
      %{"executed" => _} = m -> m
      other -> other
    end
  end
end
