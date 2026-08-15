defmodule Earss.ConcurrencyGate do
  @moduledoc """
  Leak-proof global concurrency gate for outbound provider requests.

  Each provider kind (enrichment today, TTS later) is a thin facade module
  over one instance of this server. Callers `acquire/0` before and
  `release/0` after each provider call, capping how many requests can be in
  flight at once — protecting slow external services (local models,
  TTS APIs) from request bursts.

  The gate is **leak-proof by construction**:

    * every caller is monitored — a caller that dies while holding a slot
      (e.g. a feed refresh task killed by the poller timeout) automatically
      releases it, and a queued waiter that dies is dropped from the queue
    * `release/0` is tied to the calling process — a stray or double release
      from a process that does not hold a slot is ignored

  Waiters are queued FIFO and released on check-in; there is no acquire
  timeout (a queued request eventually runs — the slot cannot leak).
  """

  use GenServer

  defstruct available: 1, waiters: :queue.new(), holders: %{}

  ## Public API — facades pass their gate name

  @doc """
  Start a gate instance. `opts`:

    * `:name` — required, registered process name (one per kind)
    * `:max_concurrency` — default `1` (fully serial provider calls)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    max_concurrency = Keyword.get(opts, :max_concurrency, 1)
    GenServer.start_link(__MODULE__, max(max_concurrency, 1), name: name)
  end

  @doc "Block until a provider slot is available (FIFO)."
  @spec acquire(GenServer.server()) :: :ok
  def acquire(gate) do
    GenServer.call(gate, :acquire, :infinity)
  end

  @doc """
  Release the calling process's provider slot.

  No-op when the calling process does not hold a slot (guards against
  stray/double releases corrupting the gate).
  """
  @spec release(GenServer.server()) :: :ok
  def release(gate) do
    GenServer.cast(gate, {:release, self()})
    :ok
  end

  ## GenServer

  @impl true
  def init(max_concurrency) do
    {:ok, %__MODULE__{available: max_concurrency}}
  end

  @impl true
  def handle_call(:acquire, {pid, _tag} = from, state) do
    ref = Process.monitor(pid)

    if state.available > 0 do
      {:reply, :ok,
       %{state | available: state.available - 1, holders: Map.put(state.holders, ref, pid)}}
    else
      {:noreply, %{state | waiters: :queue.in({from, ref}, state.waiters)}}
    end
  end

  @impl true
  def handle_cast({:release, pid}, state) do
    case holder_ref(state, pid) do
      nil ->
        {:noreply, state}

      ref ->
        state = %{state | holders: Map.delete(state.holders, ref)}
        {:noreply, hand_slot(state)}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    cond do
      Map.has_key?(state.holders, ref) ->
        # A slot holder died (killed task, crashed process, ...): its slot
        # must not leak — hand it to the next waiter or restore it.
        state = %{state | holders: Map.delete(state.holders, ref)}
        {:noreply, hand_slot(state)}

      queued_waiter_ref?(state, ref) ->
        # A queued waiter died: drop it so the queue never grows stale.
        waiters = :queue.filter(fn {_from, r} -> r != ref end, state.waiters)
        {:noreply, %{state | waiters: waiters}}

      true ->
        {:noreply, state}
    end
  end

  ## Internals

  # Hand one free slot to the oldest waiter (if any), else restore it.
  defp hand_slot(state) do
    case :queue.out(state.waiters) do
      {{:value, {{pid, _tag} = from, ref}}, rest} ->
        # The waiter was monitored while queued; it stays monitored as a
        # holder, so a later death still releases the slot.
        GenServer.reply(from, :ok)
        %{state | waiters: rest, holders: Map.put(state.holders, ref, pid)}

      {:empty, _} ->
        %{state | available: state.available + 1}
    end
  end

  defp holder_ref(state, pid) do
    Enum.find_value(state.holders, fn {ref, holder} -> if holder == pid, do: ref end)
  end

  defp queued_waiter_ref?(state, ref) do
    state.waiters
    |> :queue.to_list()
    |> Enum.any?(fn {_from, r} -> r == ref end)
  end
end
