defmodule Earss.MCP.Tools.PipelinesTest do
  @moduledoc """
  Tests for the manual translation/TTS control tools.

  Covers the feed-level and entry-level translation triggers, the TTS
  queue/retry/delete controls, and the two destructive flows
  (publish original, delete TTS request) with their confirmation phases.
  """

  use Earss.DataCase, async: false

  alias Earss.Enrichment
  alias Earss.Enrichment.Registry
  alias Earss.Feeds
  alias Earss.MCP.Handler
  alias Earss.MCP.Tools.Pipelines
  alias Earss.Reader
  alias Earss.Test.FakeTranslator
  alias Earss.TTS

  setup do
    # Register the fake translator so Registry.enricher/0 (used by the tool
    # via the registry) finds it, the same way a real plugin would register.
    # The real OpenAI plugin is unregistered first: enricher/0 picks the
    # first by id and would otherwise pick it, hitting the live provider.
    # It is restored on exit so other suites see the real plugin again.
    was_registered = Registry.fetch("openai") != :error
    Registry.unregister("openai")

    case Registry.register(%{id: FakeTranslator.id(), module: FakeTranslator, version: "test"}) do
      :ok -> :ok
      {:error, :already_registered} -> :ok
      other -> other
    end

    on_exit(fn ->
      Registry.unregister(FakeTranslator.id())

      if was_registered,
        do:
          Registry.register(%{
            id: "openai",
            module: EarssTranslateOpenai.Translator,
            version: "plugin"
          })
    end)

    {:ok, feed} =
      Feeds.create_feed(%{
        link: "https://example.com/mcp-pipe.xml",
        title: "Pipeline",
        translate_to: "zh"
      })

    {:ok, _} = Reader.subscribe(%{feed_id: feed.id, refresh: false})

    {:ok, %{entries: [a, b]}} =
      Feeds.upsert_entries(feed, [
        %{guid: "p-1", link: "https://e.com/p-1", title: "One"},
        %{guid: "p-2", link: "https://e.com/p-2", title: "Two"}
      ])

    %{feed: feed, entry_a: a, entry_b: b}
  end

  defp tool(name), do: Enum.find(Pipelines.tools(), &(&1.name == name))

  defp call(name, args \\ %{}), do: tool(name).handler.(args)

  defp via_handler(name, args) do
    {:ok, result, _state} = Handler.handle_call_tool(name, args, %{})
    result["structuredContent"] || result[:structuredContent]
  end

  describe "translate_feed/1" do
    test "translates every pending entry of the feed", %{feed: feed} do
      Enrichment.mark_pending(feed, Feeds.list_entries(feed, limit: 100))

      assert {:ok, result} = call("translate_feed", %{"feed_id" => feed.id})
      assert result.translated == 2

      # Entries are no longer pending (translations stored).
      for entry <- Feeds.list_entries(feed, limit: 100) do
        assert is_nil(entry.translation_pending_at)
      end
    end

    test "returns no_enricher-style error when nothing to do", %{feed: feed} do
      assert {:ok, result} = call("translate_feed", %{"feed_id" => feed.id})
      assert result.translated == 0
    end

    test "errors on a missing feed" do
      assert {:error, msg} = call("translate_feed", %{"feed_id" => 999_999})
      assert msg =~ "not found"
    end
  end

  describe "translate_entry/1" do
    test "translates one entry", %{feed: feed, entry_a: entry_a} do
      Enrichment.mark_pending(feed, [entry_a])

      assert {:ok, result} = call("translate_entry", %{"id" => entry_a.id})
      assert result.translated == 1
      assert is_nil(Feeds.get_entry(entry_a.id).translation_pending_at)
    end

    test "errors on a missing entry" do
      assert {:error, msg} = call("translate_entry", %{"id" => 999_999})
      assert msg =~ "not found"
    end
  end

  describe "translation_publish_original/1 — destructive" do
    test "without confirm it reports and publishes nothing", %{feed: feed} do
      Enrichment.mark_pending(feed, Feeds.list_entries(feed, limit: 100))

      report = via_handler("translation_publish_original", %{"feed_id" => feed.id})

      assert report.executed == false
      assert report.requires_confirmation == true
      assert report.pending_entries_published_as_original == 2

      # Still pending: nothing was published.
      assert length(Feeds.list_entries(feed, limit: 100)) == 2
    end

    test "with confirm it publishes originals", %{feed: feed} do
      Enrichment.mark_pending(feed, Feeds.list_entries(feed, limit: 100))

      report =
        via_handler("translation_publish_original", %{"feed_id" => feed.id, "confirm" => true})

      assert report.published == true

      for entry <- Feeds.list_entries(feed, limit: 100) do
        assert is_nil(entry.translation_pending_at)
      end
    end

    test "is destructive" do
      assert tool("translation_publish_original").destructive == true
    end
  end

  describe "tts_request/1" do
    test "queues an entry, idempotently", %{entry_a: entry_a} do
      assert {:ok, first} = call("tts_request", %{"id" => entry_a.id})
      assert first.request_id

      assert {:ok, second} = call("tts_request", %{"id" => entry_a.id})
      assert second.request_id == first.request_id
    end

    test "errors on a missing entry" do
      assert {:error, msg} = call("tts_request", %{"id" => 999_999})
      assert msg =~ "not found"
    end
  end

  describe "tts_requeue/1" do
    test "retries a failed request", %{entry_a: entry_a} do
      {:ok, req} = TTS.record_request(entry_a.id)
      # Force it into a failed state via the changeset.
      req
      |> Ecto.Changeset.change(state: :failed, error: "boom")
      |> Earss.Repo.update!()

      assert {:ok, result} = call("tts_requeue", %{"request_id" => req.id})
      assert result.state == :requested
    end

    test "errors on a missing request" do
      assert {:error, msg} = call("tts_requeue", %{"request_id" => 999_999})
      assert msg =~ "no TTS request"
    end
  end

  describe "tts_delete/1 — destructive" do
    test "without confirm it reports and keeps the request", %{entry_a: entry_a} do
      {:ok, req} = TTS.record_request(entry_a.id)

      report = via_handler("tts_delete", %{"request_id" => req.id})

      assert report.executed == false
      assert report.requires_confirmation == true
      assert report.affected == :tts_request
      assert report.entry_id == entry_a.id

      # Still there.
      assert TTS.list_requests() |> Enum.any?(&(&1.id == req.id))
    end

    test "with confirm it deletes the request", %{entry_a: entry_a} do
      {:ok, req} = TTS.record_request(entry_a.id)

      report = via_handler("tts_delete", %{"request_id" => req.id, "confirm" => true})

      assert report.deleted == true
      refute TTS.list_requests() |> Enum.any?(&(&1.id == req.id))
    end

    test "is destructive" do
      assert tool("tts_delete").destructive == true
    end
  end
end
