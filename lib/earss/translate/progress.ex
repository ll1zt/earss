defmodule Earss.Translate.Progress do
  @moduledoc """
  In-memory progress tracker for translation backfill runs (admin visibility).

  ETS-backed: the backfill loop writes `processed/total` rows as it pages
  through entries; admin pages read them to show "translating 5/15". Entries
  are deleted when a run finishes (progress is transient by design); a
  restarted app simply has no rows. Best-effort — never used for correctness.
  """

  use GenServer

  @table :earss_translate_progress

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Record the current state of a feed's backfill run."
  @spec put(integer(), map()) :: :ok
  def put(feed_id, info) when is_integer(feed_id) do
    GenServer.call(__MODULE__, {:put, feed_id, info})
  end

  @doc "Current progress for a feed (`nil` when nothing is running)."
  @spec get(integer()) :: map() | nil
  def get(feed_id) when is_integer(feed_id) do
    case :ets.lookup(@table, feed_id) do
      [{^feed_id, info}] -> info
      [] -> nil
    end
  end

  @doc "Remove the entry for a feed (run finished)."
  @spec delete(integer()) :: :ok
  def delete(feed_id) when is_integer(feed_id) do
    GenServer.call(__MODULE__, {:delete, feed_id})
  end

  # ---------------------------------------------------------------------------
  # GenServer
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:put, feed_id, info}, _from, state) do
    :ets.insert(@table, {feed_id, info})
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:delete, feed_id}, _from, state) do
    :ets.delete(@table, feed_id)
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast(_, state), do: {:noreply, state}
end
