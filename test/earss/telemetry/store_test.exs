defmodule Earss.Telemetry.StoreTest do
  use ExUnit.Case, async: false

  alias Earss.Telemetry.Store

  setup do
    unique = System.unique_integer([:positive])
    store = :"test_telemetry_store_#{unique}"
    id = {__MODULE__, unique}

    start_supervised!(%{id: id, start: {Store, :start_link, [[name: store, recent_failures: 5]]}})

    # Handler scoped to this store via config.
    :telemetry.attach(id, [:earss, :feed, :fetch], &Store.handle_event/4, %{store: store})
    on_exit(fn -> :telemetry.detach(id) end)

    %{store: store}
  end

  test "counts fetch outcomes and latency", %{store: store} do
    emit_fetch(store, :success, 1_000_000, %{feed_id: 1, link: "https://a", adapter_id: "native"})
    emit_fetch(store, :success, 3_000_000, %{feed_id: 2, link: "https://b", adapter_id: "native"})

    emit_fetch(store, :http_error, 500_000, %{feed_id: 3, link: "https://c", adapter_id: "native"})

    snap = Store.snapshot(store)

    assert snap.counters[[:earss, :feed, :fetch]] == %{
             success: 2,
             http_error: 1
           }

    assert snap.latency[[:earss, :feed, :fetch]] == %{
             count: 3,
             sum: 4_500_000,
             min: 500_000,
             max: 3_000_000
           }
  end

  test "records failed fetches as a bounded failure list", %{store: store} do
    for i <- 1..7 do
      emit_fetch(store, :adapter_error, 100_000, %{
        feed_id: i,
        link: "https://fail/#{i}",
        adapter_id: "native"
      })
    end

    snap = Store.snapshot(store)

    assert length(snap.failures) == 5
    # newest first, bounded by recent_failures: 5
    assert hd(snap.failures).feed_id == 7
    assert List.last(snap.failures).feed_id == 3
    assert Enum.all?(snap.failures, &(&1.outcome == :adapter_error))
    assert Enum.all?(snap.failures, &is_struct(&1.at, DateTime))
  end

  test "successful fetches do not land in the failure list", %{store: store} do
    emit_fetch(store, :success, 100_000, %{feed_id: 1, link: "https://ok", adapter_id: "native"})

    emit_fetch(store, :not_modified, 100_000, %{
      feed_id: 2,
      link: "https://ok2",
      adapter_id: "native"
    })

    assert Store.snapshot(store).failures == []
  end

  test "reset clears counters and failures but keeps uptime", %{store: store} do
    emit_fetch(store, :success, 100_000, %{feed_id: 1, link: "https://a", adapter_id: "native"})
    before = Store.snapshot(store)
    assert before.counters != %{}

    assert :ok = Store.reset(store)

    after_reset = Store.snapshot(store)
    assert after_reset.counters == %{}
    assert after_reset.failures == []
    assert after_reset.started_at == before.started_at
  end

  defp emit_fetch(store, outcome, duration, metadata) do
    :telemetry.execute(
      [:earss, :feed, :fetch],
      %{duration: duration, upserted: 0, skipped: 0},
      Map.put(metadata, :outcome, outcome)
    )

    # The cast and the following snapshot call share a sender, so the store
    # processes the event before answering the call.
    store
  end
end
