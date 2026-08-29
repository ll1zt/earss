defmodule Earss.TTS.ProviderContractTest do
  use ExUnit.Case, async: true

  test "api_version is 1 and matches the adapter helper" do
    assert Earss.TTS.Provider.api_version() == 1
    assert EarssTts.adapter_api_version() == 1
  end
end
