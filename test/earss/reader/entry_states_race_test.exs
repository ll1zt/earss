defmodule Earss.Reader.EntryStatesRaceTest do
  @moduledoc """
  Concurrency tests for read/starred state writes.

  Marking state used to read the row and then insert or update it. Two
  concurrent calls for the same entry both saw no row and both tried to
  insert, so one lost the unique-index race and returned "has already been
  taken". An agent marking several entries in parallel hit this immediately.

  These tests fire concurrent writes at one entry and assert every call
  succeeds, which only holds if the write is a single atomic upsert.
  """

  use Earss.DataCase, async: false

  alias Earss.Feeds
  alias Earss.Reader
  alias Earss.Repo

  setup do
    {:ok, feed} =
      Feeds.create_feed(%{link: "https://example.com/race.xml", title: "Race"})

    {:ok, %{entries: [entry]}} =
      Feeds.upsert_entries(feed, [
        %{guid: "race-1", link: "https://example.com/race-1", title: "Raced"}
      ])

    %{entry: entry}
  end

  defp concurrently(fun, count) do
    1..count
    |> Task.async_stream(fun, max_concurrency: count, timeout: 10_000)
    |> Enum.map(fn
      {:ok, result} -> result
      {:exit, reason} -> {:error, reason}
    end)
  end

  test "concurrent mark_read on one entry all succeed", %{entry: entry} do
    results = concurrently(fn _ -> Reader.mark_read(entry.id) end, 8)

    assert Enum.all?(results, &match?({:ok, _}, &1)),
           "expected all writes to succeed, got: #{inspect(results)}"

    assert Repo.get_by(Earss.Reader.EntryState, entry_id: entry.id).is_read == true
  end

  test "concurrent set_star on one entry all succeed", %{entry: entry} do
    results = concurrently(fn _ -> Reader.set_star(entry.id, true) end, 8)

    assert Enum.all?(results, &match?({:ok, _}, &1)),
           "expected all writes to succeed, got: #{inspect(results)}"

    assert Repo.get_by(Earss.Reader.EntryState, entry_id: entry.id).is_star == true
  end

  test "mixing read and star writes on one entry preserves both", %{entry: entry} do
    results =
      concurrently(
        fn i ->
          if rem(i, 2) == 0 do
            Reader.mark_read(entry.id)
          else
            Reader.set_star(entry.id, true)
          end
        end,
        8
      )

    assert Enum.all?(results, &match?({:ok, _}, &1))

    state = Repo.get_by(Earss.Reader.EntryState, entry_id: entry.id)
    assert state.is_read == true
    assert state.is_star == true
  end

  test "mark_unread clears read_at but leaves the star alone", %{entry: entry} do
    Reader.set_star(entry.id, true)
    Reader.mark_read(entry.id)

    assert {:ok, _} = Reader.mark_unread(entry.id)

    state = Repo.get_by(Earss.Reader.EntryState, entry_id: entry.id)
    assert state.is_read == false
    assert state.read_at == nil
    assert state.is_star == true
  end
end
