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

  describe "stats/0" do
    test "counts states and sums ready audio bytes", %{entry_id: entry_id} do
      {:ok, feed} = Feeds.create_feed(%{link: "https://example.com/tts_stats.xml"})

      {:ok, %{entries: [e2]}} =
        Feeds.upsert_entries(feed, [
          %{guid: "tts-stats-1", link: "https://example.com/tts-stats-1", title: "S"}
        ])

      {:ok, r1} = TTS.record_request(entry_id)
      {:ok, r2} = TTS.record_request(e2.id)

      r1
      |> Ecto.Changeset.change(state: :ready, audio_bytes: 1000)
      |> Repo.update!()

      r2
      |> Ecto.Changeset.change(state: :failed)
      |> Repo.update!()

      stats = TTS.stats()

      assert stats.ready == 1
      assert stats.failed == 1
      assert stats.requested == 0
      assert stats.processing == 0
      assert stats.audio_bytes == 1000
    end
  end

  describe "list_requests_recent/1" do
    test "orders by recent activity and preloads the entry" do
      {:ok, feed} = Feeds.create_feed(%{link: "https://example.com/tts_recent.xml"})

      {:ok, %{entries: entries}} =
        Feeds.upsert_entries(feed, [
          %{guid: "tts-recent-1", link: "https://example.com/tts-recent-1", title: "A"},
          %{guid: "tts-recent-2", link: "https://example.com/tts-recent-2", title: "B"}
        ])

      {:ok, r1} = TTS.record_request(hd(entries).id)
      {:ok, _r2} = TTS.record_request(hd(tl(entries)).id)

      # Touch the older row so it becomes the most recently active one.
      r1
      |> Ecto.Changeset.change(
        updated_at: DateTime.utc_now() |> DateTime.add(5, :second) |> DateTime.truncate(:second)
      )
      |> Repo.update!()

      assert [first, _second] = TTS.list_requests_recent()
      assert first.id == r1.id

      assert [%{entry: %Earss.Feeds.Entry{}} | _] = TTS.list_requests_recent(preload_entry: true)
    end
  end

  describe "requeue/1" do
    test "resets a failed row for the worker", %{entry_id: entry_id} do
      {:ok, request} = TTS.record_request(entry_id)

      request
      |> Ecto.Changeset.change(state: :failed, attempt_count: 5, error: "boom")
      |> Repo.update!()

      assert {:ok, requeued} = TTS.requeue(request.id)

      assert requeued.state == :requested
      assert requeued.attempt_count == 0
      assert requeued.error == nil
      assert requeued.retry_at == nil
    end

    test "requeueing an already requested row is a no-op success", %{entry_id: entry_id} do
      {:ok, request} = TTS.record_request(entry_id)
      assert {:ok, _} = TTS.requeue(request.id)
    end

    test "rejects processing and ready rows", %{entry_id: entry_id} do
      {:ok, request} = TTS.record_request(entry_id)

      request
      |> Ecto.Changeset.change(state: :ready)
      |> Repo.update!()

      assert {:error, :invalid_state} = TTS.requeue(request.id)

      request
      |> Ecto.Changeset.change(state: :processing)
      |> Repo.update!()

      assert {:error, :invalid_state} = TTS.requeue(request.id)
    end

    test "unknown id", %{entry_id: _entry_id} do
      assert {:error, :not_found} = TTS.requeue(99_999_999)
    end
  end

  describe "delete_request/1" do
    test "deletes the row and the audio file", %{entry_id: entry_id} do
      dir = System.tmp_dir!() |> Path.join("earss-tts-admin-test")
      File.rm_rf!(dir)
      File.mkdir_p!(dir)

      prev = Application.get_env(:earss, :tts)
      Application.put_env(:earss, :tts, audio_dir: dir)

      on_exit(fn ->
        File.rm_rf!(dir)
        restore_env(:earss, :tts, prev)
      end)

      {:ok, request} = TTS.record_request(entry_id)

      request
      |> Ecto.Changeset.change(state: :ready, audio_path: "gone.mp3")
      |> Repo.update!()

      path = Path.join(dir, "gone.mp3")
      File.write!(path, "audio")

      assert {:ok, %{row: true, file: true}} = TTS.delete_request(request.id)
      refute Repo.get(TTS.Request, request.id)
      refute File.exists?(path)
    end

    test "reports file: false when the file is already gone", %{entry_id: entry_id} do
      dir = System.tmp_dir!() |> Path.join("earss-tts-admin-test")
      File.rm_rf!(dir)
      File.mkdir_p!(dir)

      prev = Application.get_env(:earss, :tts)
      Application.put_env(:earss, :tts, audio_dir: dir)

      on_exit(fn -> restore_env(:earss, :tts, prev) end)

      {:ok, request} = TTS.record_request(entry_id)

      request
      |> Ecto.Changeset.change(state: :ready, audio_path: "missing.mp3")
      |> Repo.update!()

      assert {:ok, %{row: true, file: false}} = TTS.delete_request(request.id)
      refute Repo.get(TTS.Request, request.id)
    end

    test "rejects processing rows", %{entry_id: entry_id} do
      {:ok, request} = TTS.record_request(entry_id)

      request
      |> Ecto.Changeset.change(state: :processing)
      |> Repo.update!()

      assert {:error, :invalid_state} = TTS.delete_request(request.id)
      assert Repo.get(TTS.Request, request.id)
    end
  end

  describe "configured?/0" do
    test "true when rows exist, false when nothing configured" do
      {:ok, feed} = Feeds.create_feed(%{link: "https://example.com/tts_cfg.xml"})

      {:ok, %{entries: [_entry]}} =
        Feeds.upsert_entries(feed, [
          %{guid: "tts-cfg-1", link: "https://example.com/tts-cfg-1", title: "C"}
        ])

      assert TTS.configured?()

      Repo.delete_all(TTS.Request)

      prev_tts = Application.get_env(:earss, :tts)
      prev_registry = TTS.Registry.list_providers()

      Enum.each(prev_registry, &TTS.Registry.unregister(&1.id))
      Application.put_env(:earss, :tts, worker: [enabled: false])

      on_exit(fn ->
        restore_env(:earss, :tts, prev_tts)

        Enum.each(prev_registry, fn p ->
          TTS.Registry.register(%{module: p.module})
        end)
      end)

      refute TTS.configured?()
    end
  end

  defp restore_env(app, key, value) do
    if value == nil,
      do: Application.delete_env(app, key),
      else: Application.put_env(app, key, value)
  end
end
