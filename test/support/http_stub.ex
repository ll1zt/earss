defmodule Earss.Feeds.HTTPStub do
  @moduledoc false
  @behaviour Earss.Feeds.HTTP

  @impl true
  def get(url, opts) do
    case Process.get({__MODULE__, :handler}) do
      fun when is_function(fun, 2) -> fun.(url, opts)
      fun when is_function(fun, 1) -> fun.(url)
      nil -> raise "HTTPStub handler not set — call Earss.Feeds.HTTPStub.put/1 in the test"
    end
  end

  def put(fun) when is_function(fun) do
    Process.put({__MODULE__, :handler}, fun)
  end

  def clear do
    Process.delete({__MODULE__, :handler})
  end
end
