defmodule Earss.Enrichment.Limiter do
  @moduledoc """
  Global concurrency gate for outbound enrichment provider requests.

  All plugin `enrich/2` calls go through `Earss.Enrichment`'s
  `safe_enrich/3`, which `acquire/0` before and `release/0` after each
  provider call. With several feeds polled in parallel plus background
  retries, this caps how many provider requests can be in flight at once —
  protecting slow local models (Ollama/vLLM) from request bursts.

  Configuration (`config :earss, :translate`):

    * `:max_concurrency` — default `1` (fully serial provider calls)

  Waiters are queued FIFO and released on check-in; there is no timeout
  (a queued request eventually runs).
  """

  use GenServer

  @name __MODULE__

  defstruct available: 1, waiters: :queue.new()

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @doc "Block until a provider slot is available (FIFO)."
  @spec acquire() :: :ok
  def acquire do
    GenServer.call(@name, :acquire, :infinity)
  end

  @doc "Release a provider slot."
  @spec release() :: :ok
  def release do
    GenServer.cast(@name, :release)
    :ok
  end

  # ---------------------------------------------------------------------------
  # GenServer
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    {:ok, %__MODULE__{available: max(max_concurrency(), 1)}}
  end

  @impl true
  def handle_call(:acquire, from, %{available: available} = state) do
    if available > 0 do
      {:reply, :ok, %{state | available: available - 1}}
    else
      {:noreply, %{state | waiters: :queue.in(from, state.waiters)}}
    end
  end

  @impl true
  def handle_cast(:release, state) do
    case :queue.out(state.waiters) do
      {{:value, from}, rest} ->
        # Hand the slot straight to the next waiter (available stays 0).
        GenServer.reply(from, :ok)
        {:noreply, %{state | waiters: rest}}

      {:empty, _} ->
        {:noreply, %{state | available: state.available + 1}}
    end
  end

  defp max_concurrency do
    :earss |> Application.get_env(:translate, []) |> Keyword.get(:max_concurrency, 1)
  end
end
