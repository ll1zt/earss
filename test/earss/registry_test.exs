defmodule Earss.RegistryTest do
  use ExUnit.Case, async: false

  alias Earss.Registry

  defmodule FakeContract do
    def api_version, do: 1
  end

  defmodule GoodPlugin do
    def id, do: "good"
    def adapter_api, do: 1
    def work, do: :ok
  end

  defmodule WrongApiPlugin do
    def id, do: "wrong_api"
    def adapter_api, do: 99
    def work, do: :ok
  end

  defmodule MissingCallbacksPlugin do
    def id, do: "missing_callbacks"
    def adapter_api, do: 1
  end

  setup do
    unique = System.unique_integer([:positive])
    table = :"test_registry_table_#{unique}"
    server = :"test_registry_server_#{unique}"

    start_supervised!(
      {Registry,
       name: server,
       table: table,
       contract: FakeContract,
       required_callbacks: [{:work, 0}],
       not_a_module_error: :not_a_plugin}
    )

    %{table: table, server: server}
  end

  test "registers a plugin and fetches it by id", %{table: table, server: server} do
    assert :ok = Registry.register(server, %{id: "p1", module: GoodPlugin, version: "1.0"})

    assert Registry.fetch(table, "p1") == {:ok, GoodPlugin}
    assert Registry.fetch(table, "missing") == :error
    assert Registry.fetch(table, 42) == :error

    assert Enum.any?(Registry.list(table), fn t ->
             t.id == "p1" and t.module == GoodPlugin and t.version == "1.0"
           end)
  end

  test "derives the id from the module when the spec omits it", %{table: table, server: server} do
    assert :ok = Registry.register(server, %{module: GoodPlugin})
    assert Registry.fetch(table, GoodPlugin.id()) == {:ok, GoodPlugin}
  end

  test "rejects duplicate ids", %{server: server} do
    assert :ok = Registry.register(server, %{id: "dup", module: GoodPlugin})

    assert Registry.register(server, %{id: "dup", module: GoodPlugin}) ==
             {:error, :already_registered}
  end

  test "rejects modules with a mismatched adapter_api", %{server: server} do
    assert Registry.register(server, %{id: "x", module: WrongApiPlugin}) ==
             {:error, {:unsupported_adapter_api, 99, 1}}
  end

  test "rejects modules missing the required callbacks", %{server: server} do
    assert Registry.register(server, %{id: "x", module: MissingCallbacksPlugin}) ==
             {:error, :not_a_plugin}

    # nil is an atom but has no callbacks, same as the per-kind behaviour
    assert Registry.register(server, %{id: "x", module: nil}) == {:error, :not_a_plugin}
  end

  test "rejects invalid specs", %{server: server} do
    assert Registry.register(server, %{}) == {:error, :invalid_spec}

    assert Registry.register(server, %{id: "x", module: "not a module"}) ==
             {:error, :invalid_spec}
  end

  test "unregisters a plugin by id", %{table: table, server: server} do
    assert :ok = Registry.register(server, %{id: "gone", module: GoodPlugin})
    assert :ok = Registry.unregister(server, "gone")
    assert Registry.fetch(table, "gone") == :error
  end

  test "validate/2 is pure and returns normalized metadata" do
    opts = [
      contract: FakeContract,
      required_callbacks: [{:work, 0}],
      not_a_module_error: :not_a_plugin
    ]

    assert {:ok, %{id: "p1", module: GoodPlugin, version: "1.0"}} =
             Registry.validate(%{id: "p1", module: GoodPlugin, version: "1.0"}, opts)

    assert {:error, {:unsupported_adapter_api, 99, 1}} =
             Registry.validate(%{id: "x", module: WrongApiPlugin}, opts)
  end
end
