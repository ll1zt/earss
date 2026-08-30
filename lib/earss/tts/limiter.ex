defmodule Earss.TTS.Limiter do
  @moduledoc """
  Global concurrency gate for outbound TTS provider requests.

  Thin facade over the generic `Earss.ConcurrencyGate` (same pattern as
  `Earss.Enrichment.Limiter`): worker synthesis calls `acquire/0` before
  and `release/0` after each provider call, capping how many TTS requests
  are in flight — protecting the provider API from bursts.

  Configuration (`config :earss, :tts`):

    * `:max_concurrency` — default `1` (fully serial provider calls)
  """

  @gate Earss.ConcurrencyGate.TTS

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end

  def start_link(opts \\ []) do
    max_concurrency =
      :earss |> Application.get_env(:tts, []) |> Keyword.get(:max_concurrency, 1)

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
