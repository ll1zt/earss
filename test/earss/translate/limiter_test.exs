defmodule Earss.Translate.LimiterTest do
  use ExUnit.Case, async: false

  alias Earss.Translate.Limiter

  test "second acquire waits until the first is released (FIFO)" do
    # max_concurrency defaults to 1 at startup; acquire/release pairs below
    # restore the limiter state so later test files never block.
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
end
