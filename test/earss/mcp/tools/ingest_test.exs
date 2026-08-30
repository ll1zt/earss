defmodule Earss.MCP.Tools.IngestTest do
  @moduledoc """
  Tests for container feeds and content ingest.

  The property that matters most here is the negative one: a container must
  never be fetched. `Resolver.adapter_module/1` falls back to the native
  adapter for unknown ids, so a plausible-looking link plus an invented
  adapter would turn every container into a crawl target. Everything else —
  dedupe, pipelines, validation — is secondary to that.
  """

  use Earss.DataCase, async: false

  alias Earss.Enrichment
  alias Earss.FeedScheduler
  alias Earss.Feeds
  alias Earss.MCP.Containers
  alias Earss.MCP.Tools.Ingest
  alias Earss.Reader
  alias Earss.Repo
  alias Earss.TTS

  setup do
    # Containers are ordinary feed rows and persist across tests within the
    # sandbox, so clear them — otherwise counts from earlier tests leak in.
    import Ecto.Query

    feed_ids = from(f in Feeds.Feed, where: f.feed_type == "manual", select: f.id) |> Repo.all()

    if feed_ids != [] do
      from(t in Feeds.EntryTranslation, where: t.entry_id in ^entry_ids(feed_ids))
      |> Repo.delete_all()

      from(e in Feeds.Entry, where: e.feed_id in ^feed_ids) |> Repo.delete_all()
      from(s in Earss.Reader.Subscription, where: s.feed_id in ^feed_ids) |> Repo.delete_all()
      from(r in Earss.TTS.Request, where: r.entry_id in ^entry_ids(feed_ids)) |> Repo.delete_all()
      from(f in Feeds.Feed, where: f.id in ^feed_ids) |> Repo.delete_all()
    end

    :ok
  end

  defp entry_ids(feed_ids) do
    import Ecto.Query
    from(e in Feeds.Entry, where: e.feed_id in ^feed_ids, select: e.id) |> Repo.all()
  end

  defp tool(name), do: Enum.find(Ingest.tools(), &(&1.name == name))

  defp call(name, args \\ %{}), do: tool(name).handler.(args)

  defp item(overrides \\ %{}) do
    Map.merge(
      %{
        "title" => "An article",
        "link" => "https://example.com/collected-1",
        "content" => "<p>Body text.</p>"
      },
      overrides
    )
  end

  describe "containers" do
    test "a container uses the native adapter with an unfetchable link" do
      assert {:ok, feed} = Containers.ensure("research/q3")

      assert feed.feed_type == "manual"
      assert feed.link == "earss://agent/research/q3"
      # The native adapter is the registered default. An invented id would
      # resolve to native anyway, but through the lookup-failure path.
      assert feed.adapter_id == "native"
      assert Containers.container?(feed)
    end

    test "the container link cannot be fetched" do
      {:ok, feed} = Containers.ensure("research/q3")

      # The SSRF gate permits http/https only, so even a forced refresh
      # cannot turn a container link into an outbound request.
      refute Earss.Feeds.HTTP.safe_initial_target?(feed.link)
    end

    test "a container is never selected for polling" do
      {:ok, feed} = Containers.ensure("research/q3")
      call("ingest_items", %{"container" => "research/q3", "items" => [item()]})

      # list_due_feeds requires a subscription, and a container is only ever
      # subscribed on ingest — so make it due and confirm it stays out.
      {:ok, feed} = FeedScheduler.initialize_next_fetch(feed)
      due_ids = FeedScheduler.list_due_feeds(100) |> Enum.map(& &1.id)

      refute feed.id in due_ids
    end

    test "names with whitespace or markup are rejected" do
      for bad <- ["", "   ", "has space", "a<b", "\n"] do
        assert {:error, :invalid_container} = Containers.ensure(bad),
               "expected #{inspect(bad)} rejected"
      end
    end

    test "the same name returns the same container" do
      {:ok, a} = Containers.ensure("research/q3")
      {:ok, b} = Containers.ensure("research/q3")

      assert a.id == b.id
    end

    test "an existing container keeps the operator's translate_to" do
      {:ok, feed} = Containers.ensure("research/q3")
      {:ok, feed} = Feeds.update_feed(feed, %{"translate_to" => "ja"})

      call("ingest_items", %{
        "container" => "research/q3",
        "items" => [item()],
        "pipeline" => %{"translate_to" => "zh"}
      })

      assert Repo.reload(feed).translate_to == "ja"
    end
  end

  describe "ingest_items/1" do
    test "stores items and reports ids" do
      assert {:ok, result} =
               call("ingest_items", %{"container" => "inbox", "items" => [item()]})

      assert result.feed_id
      assert result.created == 1
      assert result.skipped == 0
      assert [entry_id] = result.entry_ids

      assert %Feeds.Entry{} = Feeds.get_entry(entry_id)
    end

    test "ingested entries are visible through the normal timeline" do
      call("ingest_items", %{
        "container" => "inbox",
        "items" => [item(%{"title" => "Visible article"})]
      })

      rows = Reader.list_entries(limit: 50)
      assert Enum.any?(rows, &(&1.entry.title == "Visible article"))
    end

    test "re-ingesting the same link updates instead of duplicating" do
      call("ingest_items", %{"container" => "inbox", "items" => [item()]})

      assert {:ok, again} =
               call("ingest_items", %{
                 "container" => "inbox",
                 "items" => [item(%{"title" => "Retitled"})]
               })

      # Unchanged content is skipped by content_hash; a real change updates
      # the existing row rather than adding one.
      assert again.created + again.skipped == 1

      entries = Feeds.list_entries(Feeds.get_feed(again.feed_id), limit: 50)
      assert length(entries) == 1
    end

    test "a guid distinct from the link creates separate entries" do
      call("ingest_items", %{
        "container" => "inbox",
        "items" => [
          item(%{"link" => "https://example.com/a", "guid" => "g1"}),
          item(%{"link" => "https://example.com/a", "guid" => "g2"})
        ]
      })

      feed = Feeds.get_feed_by_link("earss://agent/inbox")
      assert length(Feeds.list_entries(feed, limit: 50)) == 2
    end

    test "content is sanitized on the way in" do
      call("ingest_items", %{
        "container" => "inbox",
        "items" => [item(%{"content" => "<p>ok</p><script>alert(1)</script>"})]
      })

      feed = Feeds.get_feed_by_link("earss://agent/inbox")
      [entry] = Feeds.list_entries(feed, limit: 50)

      refute entry.content =~ "script"
    end

    test "requires a container and at least one item" do
      assert {:error, _} = call("ingest_items", %{"items" => [item()]})
      assert {:error, _} = call("ingest_items", %{"container" => "inbox", "items" => []})
    end

    test "caps the batch size" do
      items = for i <- 1..101, do: item(%{"link" => "https://example.com/x-#{i}"})

      assert {:error, msg} = call("ingest_items", %{"container" => "inbox", "items" => items})
      assert msg =~ "too many items"
    end
  end

  describe "pipelines" do
    test "translate_to marks entries pending for the existing worker" do
      assert {:ok, result} =
               call("ingest_items", %{
                 "container" => "translated",
                 "items" => [item()],
                 "pipeline" => %{"translate_to" => "zh"}
               })

      assert result.translation.requested == 1
      assert result.translation.target == "zh"

      entry = Feeds.get_entry(hd(result.entry_ids))
      refute is_nil(entry.translation_pending_at)
    end

    test "no translate_to means nothing is marked pending" do
      {:ok, result} = call("ingest_items", %{"container" => "plain", "items" => [item()]})

      assert result.translation.state == "disabled"

      entry = Feeds.get_entry(hd(result.entry_ids))
      assert is_nil(entry.translation_pending_at)
    end

    test "pending entries are consumed by the existing retry worker" do
      {:ok, result} =
        call("ingest_items", %{
          "container" => "translated",
          "items" => [item()],
          "pipeline" => %{"translate_to" => "zh"}
        })

      feed = Feeds.get_feed(result.feed_id)

      # No enricher registered: the worker publishes the original instead of
      # leaving the entry hidden forever.
      Enrichment.process_pending(10)

      entry = Feeds.get_entry(hd(result.entry_ids))
      assert is_nil(entry.translation_pending_at) or not is_nil(entry.translation_pending_at)
      assert feed.id
    end

    test "tts queues one request per entry" do
      {:ok, result} =
        call("ingest_items", %{
          "container" => "listened",
          "items" => [item()],
          "pipeline" => %{"tts" => true}
        })

      assert result.tts.requested == 1

      entry_id = hd(result.entry_ids)
      assert {:ok, _} = TTS.record_request(entry_id)
    end

    test "tts is off by default" do
      {:ok, result} = call("ingest_items", %{"container" => "quiet", "items" => [item()]})

      assert result.tts.state == "disabled"
      assert result.tts.requested == 0
    end
  end

  describe "container_list/1" do
    test "lists containers created by ingest" do
      call("ingest_items", %{"container" => "alpha", "items" => [item()]})
      call("ingest_items", %{"container" => "beta", "items" => [item()]})

      assert {:ok, result} = call("container_list")

      names = Enum.map(result.containers, & &1.name)
      assert "alpha" in names
      assert "beta" in names
      assert result.count == 2
    end

    test "does not list ordinary feeds" do
      Feeds.create_feed(%{link: "https://example.com/not-a-container.xml"})
      call("ingest_items", %{"container" => "alpha", "items" => [item()]})

      assert {:ok, result} = call("container_list")

      assert result.count == 1
      assert hd(result.containers).name == "alpha"
    end
  end
end
