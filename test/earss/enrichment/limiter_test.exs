defmodule Earss.Enrichment.LimiterTest do
  use ExUnit.Case, async: false

  alias Earss.Enrichment.Limiter

  # Runs under the app's Limiter (max_concurrency defaults to 1). Every test
  # ends with the gate fully released so later test files never block.

  test "second acquire waits until the first is released (FIFO)" do
    assert Limiter.acquire() == :ok

    waiter = Task.async(fn -> Limiter.acquire() end)
    Process.sleep(30)
    refute Task.yield(waiter, 0), "second acquire must wait for a slot"

    Limiter.release()
    assert Task.await(waiter) == :ok
    Limiter.release()

    # everything released: a fresh acquire succeeds immediately
    assert Limiter.acquire() == :ok
    Limiter.release()
  end

  test "release with no waiters restores the slot" do
    assert Limiter.acquire() == :ok
    Limiter.release()

    task = Task.async(fn -> Limiter.acquire() end)
    assert Task.await(task) == :ok
    Limiter.release()
  end

  test "slot is auto-released when the holder dies (handed to the next waiter)" do
    parent = self()

    holder =
      Task.async(fn ->
        Limiter.acquire()
        send(parent, :acquired)
        Process.sleep(:infinity)
      end)

    assert_receive :acquired, 1_000

    # slot is held: a second acquire must queue
    waiter =
      Task.async(fn ->
        Limiter.acquire()
        Limiter.release()
        :done
      end)

    Process.sleep(30)
    refute Task.yield(waiter, 0), "waiter must wait while the holder is alive"

    # killing the holder (like the poller's on_timeout: :kill_task) must NOT
    # leak the slot — the queued waiter is handed it and finishes
    Task.shutdown(holder, :brutal_kill)
    assert Task.await(waiter, 2_000) == :done
  end

  test "a dead waiter is dropped from the queue and the slot stays available" do
    parent = self()

    holder =
      Task.async(fn ->
        Limiter.acquire()
        send(parent, :acquired)
        Process.sleep(:infinity)
      end)

    assert_receive :acquired, 1_000

    waiter = Task.async(fn -> Limiter.acquire() end)
    Process.sleep(30)
    Task.shutdown(waiter, :brutal_kill)

    # release the holder: the dead waiter must not be promoted; the slot
    # must be restored so a fresh acquire succeeds immediately
    Task.shutdown(holder, :brutal_kill)

    task =
      Task.async(fn ->
        Limiter.acquire()
        Limiter.release()
        :done
      end)

    assert Task.await(task, 2_000) == :done
  end

  test "stray releases from processes that do not hold a slot are no-ops" do
    # nobody holds a slot: stray releases must not corrupt availability
    Limiter.release()
    Limiter.release()

    task =
      Task.async(fn ->
        Limiter.acquire()
        Limiter.release()
        :done
      end)

    assert Task.await(task, 2_000) == :done
  end
end
