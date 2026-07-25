defmodule Earss.Source.AdapterContractTest do
  use ExUnit.Case, async: true

  test "earss_source adapter API is version 1" do
    assert Earss.Source.Adapter.api_version() == 1
    assert EarssSource.adapter_api_version() == 1
  end
end
