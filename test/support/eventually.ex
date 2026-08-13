defmodule Earss.Test.Eventually do
  @moduledoc """
  Polling helper for assertions on asynchronous work (e.g. the ingest-hook
  translation task). Prefer an explicit `wait_until/2` over fixed sleeps so
  tests are fast when the work finishes quickly and only slow down when it
  genuinely takes longer.
  """

  @default_timeout 2_000
  @poll_interval 10

  @doc """
  Poll `fun` every `poll_interval` ms until it returns truthy or `timeout`
  ms elapse.

      assert wait_until(fn -> Repo.aggregate(EntryTranslation, :count) == 2 end)
  """
  @spec wait_until((-> boolean()), pos_integer()) :: boolean()
  def wait_until(fun, timeout \\ @default_timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

    do_wait(fun, deadline)
  end

  @doc """
  `wait_until/2` with the default timeout.

      assert eventually(fn -> Repo.aggregate(EntryTranslation, :count) == 2 end)
  """
  @spec eventually((-> boolean())) :: boolean()
  def eventually(fun), do: wait_until(fun)
  def eventually(fun, timeout), do: wait_until(fun, timeout)

  defp do_wait(fun, deadline) do
    if fun.() do
      true
    else
      if System.monotonic_time(:millisecond) >= deadline do
        false
      else
        Process.sleep(@poll_interval)
        do_wait(fun, deadline)
      end
    end
  end
end
