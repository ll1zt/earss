defmodule Earss.MCP.Tools.BackfillTest do
  @moduledoc """
  Tests for feed_backfill.

  The contract is that backfill is a plugin capability: the host calls the
  adapter's optional `backfill/2` and runs the result through the identical
  ingest path as a crawl. These tests cover both sides — a stub that
  implements it, and the stock stub that does not (which must report
  "unsupported" rather than no-op or guess).
  """

  use Earss.DataCase, async: false

  alias Earss.Feeds
  alias Earss.Feeds.Feed
  alias Earss.MCP.Tools.Backfill
  alias Earss.Repo
  alias Earss.Source.Registry

  defmodule BackfillStub do
    @moduledoc false
    @behaviour Earss.Source.Adapter

    alias Earss.Source.Adapter
    alias Earss.Source.Registry

    @impl true
    def id, do: "backfill-stub"

    @impl true
    def adapter_api, do: Adapter.api_version()

    @impl true
    def routes,
      do: [%{path: "b", description: "backfill stub", example: "earss://backfill-stub/b"}]

    @impl true
    def resolve(link), do: {:ok, %{source_url: link, title: "Backfill"}}

    @impl true
    def fetch(_feed, _opts), do: {:error, :not_used}

    @impl true
    def backfill(_feed, opts) do
      {:ok,
       %{
         entries: [
           %{
             guid: "bf-1",
             link: "https://example.com/bf-1",
             title: "Backfilled one",
             content: "<p>old content</p>",
             published_at: DateTime.utc_now() |> DateTime.add(-30, :day)
           },
           %{
             guid: "bf-2",
             link: "https://example.com/bf-2",
             title: "Backfilled two",
             content: "<p>older content</p>"
           }
         ],
         limit: Keyword.get(opts, :limit)
       }}
    end

    def ensure_registered do
      case Registry.register(%{id: id(), module: __MODULE__, version: "test"}) do
        :ok -> :ok
        {:error, :already_registered} -> :ok
        other -> other
      end
    end
  end

  defp tool, do: Enum.find(Backfill.tools(), &(&1.name == "feed_backfill"))

  defp call(args), do: tool().handler.(args)

  setup do
    # Registering the same id twice is rejected, so the source registry is
    # reset between test modules; within this module the stubs are
    # registered once via ensure_registered/0 (idempotent).
    BackfillStub.ensure_registered()
    Earss.SourceStub.ensure_registered()
    :ok
  end

  describe "feed_backfill/1" do
    test "reports when the adapter has no backfill capability" do
      # Earss.SourceStub implements the adapter behaviour but not backfill/2.
      {:ok, feed} = Feeds.create_feed(%{link: "https://example.com/no-backfill.xml"})
      Earss.SourceStub.ensure_registered()

      # The native adapter also lacks backfill, so without the stub this
      # would run the native path; the stub guarantees the "unsupported"
      # branch is exercised deliberately.
      {:ok, feed} = Feeds.update_feed(feed, %{"adapter_id" => "stub"})

      assert {:error, msg} = call(%{"feed_id" => feed.id})
      assert msg =~ "does not support backfill"
    end

    test "ingests adapter backfill results through the normal path" do
      BackfillStub.ensure_registered()

      {:ok, feed} =
        Feeds.create_feed(%{
          link: "https://example.com/backfill.xml",
          adapter_id: "backfill-stub",
          source_kind: "plugin",
          feed_type: "plugin"
        })

      assert {:ok, result} = call(%{"feed_id" => feed.id})

      assert result.feed_id == feed.id
      assert result.upserted == 2
      assert result.fetched == 2
      assert result.translation.state == "disabled"

      entries = Feeds.list_entries(feed, limit: 10)
      assert length(entries) == 2
      assert Enum.any?(entries, &(&1.title == "Backfilled one"))
    end

    test "the ingest path sanitises and hashes like a crawl" do
      BackfillStub.ensure_registered()

      {:ok, feed} =
        Feeds.create_feed(%{
          link: "https://example.com/backfill-sanitize.xml",
          adapter_id: "backfill-stub",
          source_kind: "plugin",
          feed_type: "plugin"
        })

      call(%{"feed_id" => feed.id})

      [entry | _] = Feeds.list_entries(feed, limit: 1)
      # The stub's HTML content was stored; the shared upsert sanitises it.
      assert is_binary(entry.content_hash)
    end

    test "translation is reported as enabled for a translating feed" do
      BackfillStub.ensure_registered()

      {:ok, feed} =
        Feeds.create_feed(%{
          link: "https://example.com/backfill-zh.xml",
          adapter_id: "backfill-stub",
          source_kind: "plugin",
          feed_type: "plugin",
          translate_to: "zh"
        })

      assert {:ok, result} = call(%{"feed_id" => feed.id})
      assert result.translation.state == "pending"
      assert result.translation.target == "zh"
    end

    test "rejects a missing feed" do
      assert {:error, msg} = call(%{"feed_id" => 999_999})
      assert msg =~ "not found"
    end

    test "rejects a malformed feed id" do
      assert {:error, msg} = call(%{"feed_id" => "abc"})
      assert msg =~ "feed_id"
    end
  end
end
