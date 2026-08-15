defmodule Earss.Enrichment.Limiter do
  @moduledoc """
  Global concurrency gate for outbound enrichment provider requests.

  Thin facade over the generic `Earss.ConcurrencyGate` server: all plugin
  `enrich/2` calls go through `Earss.Enrichment`'s `safe_enrich/3`, which
  `acquire/0` before and `release/0` after each provider call. With several
  feeds polled in parallel plus background retries, this caps how many
  provider requests can be in flight at once — protecting slow local models
  (Ollama/vLLM) from request bursts.

  See `Earss.ConcurrencyGate` for the leak-proof semantics (dead holders
  hand their slot to the next FIFO waiter, `release/0` is bound to the
  calling process).

  Configuration (`config :earss, :translate`):

    * `:max_concurrency` — default `1` (fully serial provider calls)
  """

  @gate Earss.ConcurrencyGate.Enrichment

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end

  def start_link(opts \\ []) do
    max_concurrency =
      :earss |> Application.get_env(:translate, []) |> Keyword.get(:max_concurrency, 1)

    Earss.ConcurrencyGate.start_link(opts ++ [name: @gate, max_concurrency: max_concurrency])
  end

  @doc "Block until a provider slot is available (FIFO)."
  @spec acquire() :: :ok
  def acquire, do: Earss.ConcurrencyGate.acquire(@gate)

  @doc """
  Release the calling process's provider slot.

  No-op when the calling process does not hold a slot (guards against
  stray/double releases corrupting the gate).
  """
  @spec release() :: :ok
  def release, do: Earss.ConcurrencyGate.release(@gate)
end
