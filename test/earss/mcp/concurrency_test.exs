defmodule Earss.MCP.ConcurrencyTest do
  @moduledoc """
  Concurrent tool calls against the real handler.

  An agent client fires tool calls in parallel, so a tool that is only safe
  sequentially is broken in practice. These tests run the read tools
  concurrently and assert every call returns — a server-side crash here is
  what shows up client-side as an SDK error rather than a clean MCP error,
  and is much harder to diagnose.
  """

  use Earss.DataCase, async: false

  alias Earss.Feeds
  alias Earss.MCP.Handler
  alias Earss.MCP.Tools.Reading
  alias Earss.Reader

  setup do
    {:ok, feed} =
      Feeds.create_feed(%{link: "https://example.com/mcp-concurrent.xml", title: "Concurrent"})

    {:ok, _} = Reader.subscribe(%{feed_id: feed.id, refresh: false})

    {:ok, %{entries: entries}} =
      Feeds.upsert_entries(feed, [
        %{
          guid: "c-1",
          link: "https://e.com/c-1",
          title: "One about bugs",
          content: "<p>bugs</p>"
        },
        %{
          guid: "c-2",
          link: "https://e.com/c-2",
          title: "Two about feeds",
          content: "<p>feeds</p>"
        }
      ])

    %{feed: feed, entries: entries}
  end

  defp handler_tool(name), do: Enum.find(Reading.tools(), &(&1.name == name))

  defp call(name, args), do: handler_tool(name).handler.(args)

  test "parallel entry_search all succeed" do
    results =
      1..12
      |> Task.async_stream(
        fn _ -> call("entry_search", %{"query" => "bugs"}) end,
        max_concurrency: 12,
        timeout: 10_000
      )
      |> Enum.map(fn
        {:ok, {:ok, _}} -> :ok
        {:ok, other} -> {:bad, other}
        {:exit, reason} -> {:exit, reason}
      end)

    assert Enum.all?(results, &(&1 == :ok)),
           "expected all concurrent searches to succeed, got: #{inspect(results)}"
  end

  test "parallel mixed reads all succeed" do
    tools = [
      fn -> call("entry_search", %{"query" => "bugs"}) end,
      fn -> call("entry_list", %{}) end,
      fn -> call("feed_list", %{}) end
    ]

    results =
      1..12
      |> Task.async_stream(
        fn i -> Enum.at(tools, rem(i, 3)).() end,
        max_concurrency: 12,
        timeout: 10_000
      )
      |> Enum.map(fn
        {:ok, {:ok, _}} -> :ok
        {:ok, other} -> {:bad, other}
        {:exit, reason} -> {:exit, reason}
      end)

    assert Enum.all?(results, &(&1 == :ok)),
           "expected all concurrent reads to succeed, got: #{inspect(results)}"
  end

  test "handler list stays deterministic across calls" do
    {:ok, first, _cursor, _state} = Handler.handle_list_tools(nil, %{})
    {:ok, second, _cursor, _state} = Handler.handle_list_tools(nil, %{})

    assert Enum.map(first, & &1.name) == Enum.map(second, & &1.name)
  end
end
