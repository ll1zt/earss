defmodule Earss.Feeds.HTTPStub do
  @moduledoc false
  @behaviour Earss.Feeds.HTTP

  @table :earss_http_stub

  def ensure_table! do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

      _tid ->
        @table
    end
  end

  @impl true
  def get(url, opts) do
    ensure_table!()

    case :ets.lookup(@table, :handler) do
      [{:handler, fun}] when is_function(fun, 2) -> fun.(url, opts)
      [{:handler, fun}] when is_function(fun, 1) -> fun.(url)
      [] -> raise "HTTPStub handler not set — call Earss.Feeds.HTTPStub.put/1 in the test"
    end
  end

  def put(fun) when is_function(fun) do
    ensure_table!()
    :ets.insert(@table, {:handler, fun})
    :ok
  end

  def clear do
    case :ets.whereis(@table) do
      :undefined -> :ok
      _ -> :ets.delete_all_objects(@table)
    end
  end
end
