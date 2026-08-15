defmodule Earss.TelemetryTest do
  use Earss.DataCase

  alias Earss.Feeds
  alias Earss.Feeds.HTTPStub

  setup do
    previous = Application.get_env(:earss, :http_client)
    Application.put_env(:earss, :http_client, HTTPStub)

    on_exit(fn ->
      HTTPStub.clear()

      if previous do
        Application.put_env(:earss, :http_client, previous)
      else
        Application.delete_env(:earss, :http_client)
      end
    end)

    :ok
  end

  # Attach a handler that forwards events to the test process; detached on
  # exit so other tests never see these events. The handler runs in the
  # emitting process, so the test pid must be captured, not self() at call
  # time.
  defp attach!(event) do
    ref = make_ref()
    test_pid = self()

    :telemetry.attach(
      ref,
      event,
      fn event_name, measurements, metadata, _config ->
        send(test_pid, {:telemetry, ref, event_name, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(ref) end)
    ref
  end

  defp fixture(name) do
    Path.join([File.cwd!(), "test/fixtures/feeds", name]) |> File.read!()
  end

  test "feed fetch emits an outcome-coded event" do
    body = fixture("sample.rss.xml")

    HTTPStub.put(fn _url, _opts ->
      {:ok, %{status: 200, body: body, etag: "\"abc\"", last_modified: "Mon, 01 Jan 2024 00:00:00 GMT"}}
    end)

    {:ok, feed} = Feeds.create_feed(%{link: "https://example.com/tel_fetch.xml"})

    attach!(Earss.Telemetry.event_feed_fetch())

    assert {:ok, %{upserted: 2, skipped: 0}} = Feeds.refresh(feed)

    assert_receive {:telemetry, _ref, [:earss, :feed, :fetch], measurements, metadata}
    assert is_integer(measurements.duration) and measurements.duration >= 0
    assert measurements.upserted == 2
    assert metadata.feed_id == feed.id
    assert metadata.link == "https://example.com/tel_fetch.xml"
    assert metadata.outcome == :success
  end

  test "fetch failures are outcome-coded (adapter error)" do
    HTTPStub.put(fn _url, _opts -> {:error, :timeout} end)

    {:ok, feed} = Feeds.create_feed(%{link: "https://example.com/tel_fail.xml"})

    attach!(Earss.Telemetry.event_feed_fetch())

    assert {:error, {:adapter, :timeout}} = Feeds.refresh(feed)

    assert_receive {:telemetry, _ref, [:earss, :feed, :fetch], _measurements, metadata}
    assert metadata.outcome == :adapter_error
  end

  test "poller tick emits a cycle event" do
    attach!(Earss.Telemetry.event_poller_tick())

    start_supervised!(
      {Earss.FeedPoller,
       interval_ms: 60_000,
       batch_size: 5,
       max_concurrency: 2,
       initial_delay_ms: 1_000_000,
       timeout_ms: 1_000}
    )

    Earss.FeedPoller.poll_now()

    assert_receive {:telemetry, _ref, [:earss, :poller, :tick], measurements, _metadata}
    assert is_integer(measurements.duration) and measurements.duration >= 0
    assert measurements.feeds == 0
    assert measurements.ok == 0
    assert measurements.failed == 0
  end

  test "ingest-hook translation emits an event" do
    {:ok, feed} = Feeds.create_feed(%{link: "https://example.com/tel_tr.xml"})

    {:ok, entry} =
      Feeds.upsert_entry(feed, %{link: "https://example.com/tel_tr.xml/1", guid: "g1", title: "T"})

    attach!(Earss.Telemetry.event_enrichment_translate())

    assert {:ok, 0} = Earss.Enrichment.enrich_new_entries(feed, [entry])

    assert_receive {:telemetry, _ref, [:earss, :enrichment, :translate], measurements, metadata}
    assert is_integer(measurements.duration) and measurements.duration >= 0
    assert measurements.entries == 1
    assert measurements.translated == 0
    assert metadata.feed_id == feed.id
  end

  test "pending worker cycle emits an event" do
    attach!(Earss.Telemetry.event_enrichment_pending())

    assert Earss.Enrichment.process_pending(10) == 0

    assert_receive {:telemetry, _ref, [:earss, :enrichment, :pending], measurements, _metadata}
    assert is_integer(measurements.duration) and measurements.duration >= 0
    assert measurements.processed == 0
  end

  test "retention run emits an event" do
    attach!(Earss.Telemetry.event_retention_run())

    assert %{states: %{deleted: 0}} = Earss.Retention.run_all(dry_run: true)

    assert_receive {:telemetry, _ref, [:earss, :retention, :run], measurements, metadata}
    assert is_integer(measurements.duration) and measurements.duration >= 0
    assert metadata.dry_run == true
  end
end
