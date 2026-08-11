defmodule Earss.Translate.ProgressTest do
  use ExUnit.Case, async: false

  alias Earss.Translate.Progress

  test "put/get/delete lifecycle" do
    id = System.unique_integer([:positive])
    assert Progress.get(id) == nil

    Progress.put(id, %{status: :running, processed: 2, total: 5})
    assert Progress.get(id) == %{status: :running, processed: 2, total: 5}

    Progress.delete(id)
    assert Progress.get(id) == nil
  end

  test "get for a missing feed returns nil" do
    assert Progress.get(System.unique_integer([:positive])) == nil
  end
end
