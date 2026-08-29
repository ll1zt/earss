defmodule Earss.TtsTest do
  use Earss.DataCase

  alias Earss.Feeds
  alias Earss.TTS

  setup do
    {:ok, feed} = Feeds.create_feed(%{link: "https://example.com/tts_test.xml"})

    {:ok, %{entries: entries}} =
      Feeds.upsert_entries(feed, [
        %{
          guid: "tts-test-1",
          link: "https://example.com/tts-test-1",
          title: "First article",
          content: "<p>Hello</p>"
        }
      ])

    [entry_id: hd(entries).id]
  end

  describe "record_request/1" do
    test "records a request for an existing entry", %{entry_id: entry_id} do
      assert {:ok, request} = TTS.record_request(entry_id)
      assert request.entry_id == entry_id
      assert request.state == :requested
    end

    test "is idempotent — repeated requests return the same row", %{entry_id: entry_id} do
      {:ok, first} = TTS.record_request(entry_id)
      {:ok, second} = TTS.record_request(entry_id)

      assert first.id == second.id
      assert [_one_row] = TTS.list_requests()
    end

    test "rejects unknown entries" do
      assert {:error, :unknown_entry} = TTS.record_request(9_999_999)
    end

    test "rejects non-integer input" do
      assert {:error, :unknown_entry} = TTS.record_request("123")
      assert {:error, :unknown_entry} = TTS.record_request(-1)
    end
  end

  describe "list_requests/1" do
    test "lists in insertion order and filters by state", %{entry_id: entry_id} do
      {:ok, feed} = Feeds.create_feed(%{link: "https://example.com/tts_test_2.xml"})

      {:ok, %{entries: [second]}} =
        Feeds.upsert_entries(feed, [
          %{
            guid: "tts-test-2",
            link: "https://example.com/tts-test-2",
            title: "Second",
            content: "<p>Bye</p>"
          }
        ])

      {:ok, r1} = TTS.record_request(entry_id)
      {:ok, r2} = TTS.record_request(second.id)

      assert [first_row, second_row] = TTS.list_requests()
      assert first_row.id in [r1.id, r2.id]
      assert second_row.id in [r1.id, r2.id]
      assert first_row.id < second_row.id

      # state filter only matches what the pipeline has not consumed yet
      assert length(TTS.list_requests(state: :requested)) == 2
    end
  end
end
