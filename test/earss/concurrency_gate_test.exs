defmodule Earss.ConcurrencyGateTest do
  use ExUnit.Case, async: false

  alias Earss.ConcurrencyGate

  setup do
    unique = System.unique_integer([:positive])
    gate = :"test_gate_#{unique}"

    start_supervised!({ConcurrencyGate, name: gate, max_concurrency: 1})
    %{gate: gate}
  end

  test "second acquire waits until the first is released (FIFO)", %{gate: gate} do
    assert ConcurrencyGate.acquire(gate) == :ok

    waiter = Task.async(fn -> ConcurrencyGate.acquire(gate) end)
    Process.sleep(30)
    refute Task.yield(waiter, 0), "second acquire must wait for a slot"

    ConcurrencyGate.release(gate)
    assert Task.await(waiter) == :ok
    ConcurrencyGate.release(gate)

    # everything released: a fresh acquire succeeds immediately
    assert ConcurrencyGate.acquire(gate) == :ok
    ConcurrencyGate.release(gate)
  end

  test "release with no waiters restores the slot", %{gate: gate} do
    assert ConcurrencyGate.acquire(gate) == :ok
    ConcurrencyGate.release(gate)

    task = Task.async(fn -> ConcurrencyGate.acquire(gate) end)
    assert Task.await(task) == :ok
    ConcurrencyGate.release(gate)
  end

  test "slot is auto-released when the holder dies (handed to the next waiter)", %{gate: gate} do
    parent = self()

    holder =
      Task.async(fn ->
        ConcurrencyGate.acquire(gate)
        send(parent, :acquired)
        Process.sleep(:infinity)
      end)

    assert_receive :acquired, 1_000

    # slot is held: a second acquire must queue
    waiter =
      Task.async(fn ->
        ConcurrencyGate.acquire(gate)
        ConcurrencyGate.release(gate)
        :done
      end)

    Process.sleep(30)
    refute Task.yield(waiter, 0), "waiter must wait while the holder is alive"

    # killing the holder (like the poller's on_timeout: :kill_task) must NOT
    # leak the slot — the queued waiter is handed it and finishes
    Task.shutdown(holder, :brutal_kill)
    assert Task.await(waiter, 2_000) == :done
  end

  test "a dead waiter is dropped from the queue and the slot stays available", %{gate: gate} do
    parent = self()

    holder =
      Task.async(fn ->
        ConcurrencyGate.acquire(gate)
        send(parent, :acquired)
        Process.sleep(:infinity)
      end)

    assert_receive :acquired, 1_000

    waiter = Task.async(fn -> ConcurrencyGate.acquire(gate) end)
    Process.sleep(30)
    Task.shutdown(waiter, :brutal_kill)

    # release the holder: the dead waiter must not be promoted; the slot
    # must be restored so a fresh acquire succeeds immediately
    Task.shutdown(holder, :brutal_kill)

    task =
      Task.async(fn ->
        ConcurrencyGate.acquire(gate)
        ConcurrencyGate.release(gate)
        :done
      end)

    assert Task.await(task, 2_000) == :done
  end

  test "stray releases from processes that do not hold a slot are no-ops", %{gate: gate} do
    # nobody holds a slot: stray releases must not corrupt availability
    ConcurrencyGate.release(gate)
    ConcurrencyGate.release(gate)

    task =
      Task.async(fn ->
        ConcurrencyGate.acquire(gate)
        ConcurrencyGate.release(gate)
        :done
      end)

    assert Task.await(task, 2_000) == :done
  end

  test "max_concurrency > 1 admits that many concurrent holders", %{gate: gate} do
    unique = System.unique_integer([:positive])
    wide = :"test_gate_wide_#{unique}"

    start_supervised!(
      %{
        id: :wide_gate,
        start: {ConcurrencyGate, :start_link, [[name: wide, max_concurrency: 3]]}
      }
    )
    parent = self()

    holders =
      for _ <- 1..3 do
        Task.async(fn ->
          ConcurrencyGate.acquire(wide)
          send(parent, :acquired)
          Process.sleep(:infinity)
        end)
      end

    # all three acquire immediately (no queueing at 3 slots)
    for _ <- 1..3, do: assert_receive(:acquired, 1_000)

    # a fourth must queue until a holder releases
    fourth =
      Task.async(fn ->
        ConcurrencyGate.acquire(wide)
        ConcurrencyGate.release(wide)
        :done
      end)

    Process.sleep(30)
    refute Task.yield(fourth, 0), "fourth acquire must wait"

    Task.shutdown(Enum.at(holders, 0), :brutal_kill)
    assert Task.await(fourth, 2_000) == :done

    Task.shutdown(Enum.at(holders, 1), :brutal_kill)
    Task.shutdown(Enum.at(holders, 2), :brutal_kill)
  end
end
