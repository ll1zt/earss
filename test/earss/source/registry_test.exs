defmodule Earss.Source.RegistryTest do
  use ExUnit.Case, async: false

  alias Earss.Source.Registry
  alias Earss.Source.Native
  alias Earss.Source.Resolver

  test "native adapter is registered at app start" do
    assert {:ok, Native} = Registry.fetch("native")
    assert Enum.any?(Registry.list_adapters(), &(&1.id == "native"))
  end

  test "resolver maps https to native" do
    assert Resolver.adapter_id("https://example.com/feed.xml") == "native"
    assert Resolver.adapter_module("https://example.com/feed.xml") == Native
  end

  test "resolver maps earss://host/path to adapter id" do
    assert Resolver.adapter_id("earss://bilibili/user/1") == "bilibili"
  end

  test "native resolve accepts https and rejects earss" do
    assert {:ok, %{source_url: "https://example.com/a.xml"}} =
             Native.resolve("https://example.com/a.xml")

    assert {:error, :unsupported_scheme} = Native.resolve("earss://example/x")
  end

  test "duplicate register is rejected" do
    assert {:error, :already_registered} =
             Registry.register(%{id: "native", module: Native})
  end
end
