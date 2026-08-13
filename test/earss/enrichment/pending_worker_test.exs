defmodule Earss.Enrichment.PendingWorkerTest do
  # Sequential: the tests share the global enricher registry and the app's
  # Limiter, so they must not run concurrently with each other.
  use Earss.DataCase, async: false

  alias Earss.Repo
  alias Earss.Feeds
  alias Earss.Feeds.{Entry, EntryTranslation}
  alias Earss.Enrichment
  alias Earss.Enrichment.PendingWorker
  alias Earss.Test.FakeTranslator

  # A slow enricher: sleeps inside enrich/2 to prove a provider call in
  # flight never blocks the worker's GenServer (async tick).
  defmodule SlowEnricher do
    @behaviour Earss.Source.Enricher

    @impl true
    def id, do: "aaa0_pw_slow"

    @impl true
    def adapter_api, do: Earss.Source.Enricher.api_version()

    @impl true
    def provider_info, do: %{name: "slow", base_url: nil, model: "slow"}

    @impl true
    def enrich(_payloads, _opts) do
      Process.sleep(500)
      {:error, :provider_down}
    end
  end

  # Sort before the real plugin's id ("openai") so the registry picks the
  # fake; the slow enricher's "aaa0_..." id sorts before this one.
  @fake_id "aaa1_pw_test_fake"

  setup do
    # The worker runs process_pending in a separate Task process; share the
    # sandbox (owned by this test process) so that task can query.
    case Ecto.Adapters.SQL.Sandbox.mode(Earss.Repo, {:shared, self()}) do
      :ok -> :ok
      :already_shared -> :ok
      other -> other
    end

    :ok = Earss.Enrichment.Registry.register(%{id: @fake_id, module: FakeTranslator})
    on_exit(fn -> Earss.Enrichment.Registry.unregister(@fake_id) end)
    :ok
  end

  defp unique_link, do: "https://example.com/pw_#{System.unique_integer([:positive])}.xml"

  defp insert_pending_entry!(feed) do
    n = System.unique_integer([:positive])

    {:ok, entry} =
      Repo.insert(
        Entry.changeset(%Entry{}, %{
          feed_id: feed.id,
          link: "https://example.com/p/#{n}",
          guid: "guid-#{n}",
          title: "Hello world",
          content: "<p>See details.</p>",
          content_hash: "hash-#{n}"
        })
      )

    :ok = Enrichment.mark_pending(feed, [entry])
    entry
  end

  defp wait_until(fun, timeout_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Enum.reduce_while(1..10_000, false, fn _, _ ->
      cond do
        fun.() ->
          {:halt, true}

        System.monotonic_time(:millisecond) > deadline ->
          {:halt, false}

        true ->
          Process.sleep(50)
          {:cont, false}
      end
    end)
  end

  test "translates pending entries on its cadence" do
    {:ok, feed} = Feeds.create_feed(%{link: unique_link(), translate_to: "zh"})
    entry = insert_pending_entry!(feed)

    {:ok, pid} = PendingWorker.start_link(interval_ms: 50, name: :earss_pw_test)
    on_exit(fn -> Process.exit(pid, :kill) end)

    translated? = fn ->
      t = Repo.get_by(EntryTranslation, entry_id: entry.id, lang: "zh")
      e = Repo.get(Entry, entry.id)
      t != nil and e.translation_pending_at == nil
    end

    assert wait_until(translated?), "the pending worker should translate the entry"
    assert Repo.get!(Entry, entry.id).translation_pending_at == nil

    assert Repo.get_by(EntryTranslation, entry_id: entry.id, lang: "zh").model ==
             "test_translator"
  end

  test "a slow provider run does not block the worker process (async tick)" do
    slow_id = "aaa0_pw_slow_#{System.unique_integer([:positive])}"
    :ok = Earss.Enrichment.Registry.register(%{id: slow_id, module: SlowEnricher})
    on_exit(fn -> Earss.Enrichment.Registry.unregister(slow_id) end)

    {:ok, feed} = Feeds.create_feed(%{link: unique_link(), translate_to: "zh"})
    _entry = insert_pending_entry!(feed)

    {:ok, pid} = PendingWorker.start_link(interval_ms: 50, name: :earss_pw_slow_test)
    on_exit(fn -> Process.exit(pid, :kill) end)

    # Let the first tick fire and start the 500ms provider run.
    Process.sleep(150)

    started = System.monotonic_time(:millisecond)
    state = :sys.get_state(pid)
    elapsed = System.monotonic_time(:millisecond) - started

    # The worker must answer immediately while the run is in flight — with a
    # synchronous tick this would block for the whole 500ms sleep.
    assert elapsed < 250, "worker blocked for #{elapsed}ms during a slow provider run"
    assert state.running == true
  end
end
