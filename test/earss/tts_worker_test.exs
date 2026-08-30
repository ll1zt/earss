defmodule Earss.TtsWorkerTest do
  use Earss.DataCase, async: false

  import Earss.Test.Eventually

  alias Earss.Feeds
  alias Earss.Repo
  alias Earss.TTS
  alias Earss.TTS.{Registry, Worker}
  alias Earss.Test.FakeTtsProvider

  @audio_dir System.tmp_dir!() |> Path.join("earss-tts-worker-test")

  setup do
    File.rm_rf!(@audio_dir)
    FakeTtsProvider.reset()
    Registry.unregister(FakeTtsProvider.id())
    assert :ok = TTS.Registry.register(%{module: FakeTtsProvider})

    on_exit(fn ->
      File.rm_rf!(@audio_dir)
      TTS.Registry.unregister(FakeTtsProvider.id())
      FakeTtsProvider.reset()
    end)

    {:ok, feed} = Feeds.create_feed(%{link: "https://example.com/tts_worker.xml"})

    {:ok, %{entries: [entry]}} =
      Feeds.upsert_entries(feed, [
        %{
          guid: "tts-worker-1",
          link: "https://example.com/tts-worker-1",
          title: "An article worth hearing",
          content: "<p>First paragraph of the article.</p><p>Second one.</p>"
        }
      ])

    {:ok, request} = TTS.record_request(entry.id)

    %{entry_id: entry.id, request_id: request.id}
  end

  describe "process_job/3 (sync path)" do
    test "synthesizes, stores the file and marks the row ready", %{
      request_id: request_id,
      entry_id: entry_id
    } do
      :ok =
        Worker.process_job(request(request_id), FakeTtsProvider,
          audio_dir: @audio_dir,
          worker: [max_chars_sync: 2_500]
        )

      row = Repo.get!(TTS.Request, request_id)
      assert row.state == :ready
      assert row.provider == "fake-tts"
      assert row.audio_path == "#{entry_id}.mp3"
      assert row.audio_bytes == 8
      assert row.audio_duration_secs != nil
      assert File.read!(Path.join(@audio_dir, "#{entry_id}.mp3")) == <<1, 2, 3, 4, 5, 6, 7, 8>>
      assert FakeTtsProvider.calls() |> Enum.any?(&match?({:synthesize, _}, &1))
    end

    test "long text goes through the async job path", %{request_id: request_id} do
      long_text = String.duplicate("word ", 600)
      {:ok, feed} = Feeds.create_feed(%{link: "https://example.com/tts_worker_long.xml"})

      {:ok, %{entries: [long_entry]}} =
        Feeds.upsert_entries(feed, [
          %{guid: "long", link: "https://example.com/long", title: "Long", content: long_text}
        ])

      {:ok, long_request} = TTS.record_request(long_entry.id)

      :ok =
        Worker.process_job(request(long_request.id), FakeTtsProvider,
          audio_dir: @audio_dir,
          worker: [max_chars_sync: 100, poll_interval_ms: 1, poll_attempts: 3]
        )

      assert Repo.get!(TTS.Request, request_id) == Repo.get!(TTS.Request, request_id)

      row = Repo.get!(TTS.Request, long_request.id)
      assert row.state == :ready
      assert FakeTtsProvider.calls() |> Enum.any?(&match?({:submit, _}, &1))
      assert FakeTtsProvider.calls() |> Enum.any?(&match?({:download, _}, &1))
    end

    test "leaves no temp file behind and no half-written audio", %{
      request_id: request_id,
      entry_id: entry_id
    } do
      :ok =
        Worker.process_job(request(request_id), FakeTtsProvider,
          audio_dir: @audio_dir,
          worker: [max_chars_sync: 2_500]
        )

      # The visible file is complete, and the staging name never survives.
      assert File.read!(Path.join(@audio_dir, "#{entry_id}.mp3")) == <<1, 2, 3, 4, 5, 6, 7, 8>>

      leftovers = File.ls!(@audio_dir) |> Enum.reject(&(&1 == "#{entry_id}.mp3"))
      assert leftovers == [], "unexpected files in audio_dir: #{inspect(leftovers)}"
    end

    test "a failing DB update does not leave the audio file orphaned", %{
      request_id: request_id,
      entry_id: entry_id
    } do
      # Delete the row behind the worker's back so the final `Repo.update!`
      # raises (stale entry) — the file is already on disk at that point.
      stale = request(request_id)
      Repo.delete!(stale)

      :ok =
        Worker.process_job(stale, FakeTtsProvider,
          audio_dir: @audio_dir,
          worker: [max_chars_sync: 2_500]
        )

      leftovers = File.ls!(@audio_dir)

      assert "#{entry_id}.mp3" not in leftovers,
             "audio survived a failed row update and is now an orphan"

      assert leftovers == [], "unexpected files in audio_dir: #{inspect(leftovers)}"
    end

    test "provider failure backs off with attempt_count and retry_at", %{
      request_id: request_id
    } do
      FakeTtsProvider.put_script(:synthesize, :fail)

      :ok =
        Worker.process_job(request(request_id), FakeTtsProvider, audio_dir: @audio_dir)

      row = Repo.get!(TTS.Request, request_id)
      assert row.state == :requested
      assert row.attempt_count == 1
      assert row.retry_at != nil
      assert row.error =~ "scripted_failure"
    end

    test "past max_retries the row settles in failed", %{request_id: request_id} do
      FakeTtsProvider.put_script(:synthesize, :fail)

      :ok =
        Worker.process_job(request(request_id), FakeTtsProvider,
          audio_dir: @audio_dir,
          worker: [max_retries: 1]
        )

      assert Repo.get!(TTS.Request, request_id).state == :failed
    end

    test "entries without readable text fail with :no_readable_text", %{
      request_id: request_id
    } do
      {:ok, feed} = Feeds.create_feed(%{link: "https://example.com/tts_worker_empty.xml"})

      {:ok, %{entries: [empty_entry]}} =
        Feeds.upsert_entries(feed, [
          %{guid: "empty", link: "https://example.com/empty", title: ""}
        ])

      {:ok, empty_request} = TTS.record_request(empty_entry.id)

      :ok = Worker.process_job(request(empty_request.id), FakeTtsProvider, audio_dir: @audio_dir)

      row = Repo.get!(TTS.Request, empty_request.id)
      assert row.error =~ "no_readable_text"
      assert Repo.get!(TTS.Request, request_id).state == :requested
    end
  end

  describe "tick loop (enabled)" do
    test "claims requested rows and drives them to ready", %{
      request_id: request_id,
      entry_id: entry_id
    } do
      # Allow the supervised worker (another process) to use the sandbox connection.
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      start_supervised!(
        {Worker,
         worker: [
           enabled: true,
           interval_ms: 50,
           batch_size: 5,
           poll_interval_ms: 1,
           poll_attempts: 3
         ],
         audio_dir: @audio_dir}
      )

      assert eventually(fn ->
               row = Repo.get!(TTS.Request, request_id)
               row.state == :ready and File.exists?(Path.join(@audio_dir, "#{entry_id}.mp3"))
             end)
    end

    test "orphaned processing rows are requeued after the lease expires", %{
      request_id: request_id
    } do
      row = Repo.get!(TTS.Request, request_id)

      row
      |> Ecto.Changeset.change(state: :processing)
      |> Repo.update!()

      # Backdate the row past the lease window.
      past = DateTime.utc_now() |> DateTime.add(-3_600, :second) |> DateTime.truncate(:second)

      Repo.update_all(
        from(r in TTS.Request, where: r.id == ^request_id),
        set: [updated_at: past]
      )

      assert Worker.recover_stuck(worker_cfg()) == 1

      requeued = Repo.get!(TTS.Request, request_id)
      assert requeued.state == :requested
      assert requeued.error =~ "lease expired"
      # The lease expiry counts as an attempt and schedules a backoff retry.
      assert requeued.attempt_count == 1
      assert requeued.retry_at != nil
    end

    test "orphaned processing rows past max retries settle in failed", %{
      request_id: request_id
    } do
      Repo.get!(TTS.Request, request_id)
      |> Ecto.Changeset.change(state: :processing, attempt_count: 5)
      |> Repo.update!()

      past = DateTime.utc_now() |> DateTime.add(-3_600, :second) |> DateTime.truncate(:second)

      Repo.update_all(
        from(r in TTS.Request, where: r.id == ^request_id),
        set: [updated_at: past]
      )

      assert Worker.recover_stuck(worker_cfg()) == 1

      failed = Repo.get!(TTS.Request, request_id)
      assert failed.state == :failed
      assert failed.error =~ "gave up after max retries"
    end

    test "fresh processing rows are left alone", %{request_id: request_id} do
      Repo.get!(TTS.Request, request_id)
      |> Ecto.Changeset.change(state: :processing)
      |> Repo.update!()

      assert Worker.recover_stuck(worker_cfg()) == 0
      assert Repo.get!(TTS.Request, request_id).state == :processing
    end

    test "rows stay requested when no provider is registered", %{request_id: request_id} do
      TTS.Registry.unregister(FakeTtsProvider.id())
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      start_supervised!({Worker, worker: [enabled: true, interval_ms: 20], audio_dir: @audio_dir})

      Process.sleep(120)
      assert Repo.get!(TTS.Request, request_id).state == :requested
    end
  end

  defp request(id), do: Repo.get!(TTS.Request, id)

  defp worker_cfg do
    %{processing_lease_secs: 1_800, max_retries: 5}
  end
end
