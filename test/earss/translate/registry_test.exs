defmodule Earss.Translate.RegistryTest do
  use ExUnit.Case, async: false

  alias Earss.Translate.Registry

  defmodule FakeTranslator do
    @behaviour Earss.Source.Translator

    @impl true
    def id, do: "fake"

    @impl true
    def adapter_api, do: Earss.Source.Translator.api_version()

    @impl true
    def provider_info, do: %{name: "Fake", base_url: nil, model: nil}

    @impl true
    def translate(_items, _opts), do: {:ok, []}
  end

  defmodule WrongVersionTranslator do
    @behaviour Earss.Source.Translator

    @impl true
    def id, do: "wrong"

    @impl true
    def adapter_api, do: 99

    @impl true
    def provider_info, do: %{name: "Wrong"}

    @impl true
    def translate(_items, _opts), do: {:ok, []}
  end

  defp unique_id, do: "fake_#{System.unique_integer([:positive])}"

  # Register with a unique id and always clean it up so the global Registry
  # never leaks fake translators into other test files. An empty/omitted id
  # falls back to the module's id/0 — unregister that real id.
  defp register_and_cleanup!(spec) do
    assert Registry.register(spec) == :ok

    real_id =
      if spec.id in [nil, ""], do: spec.module.id(), else: spec.id

    on_exit(fn -> Registry.unregister(real_id) end)
    real_id
  end

  test "registers a translator and fetches it by id" do
    id = register_and_cleanup!(%{id: unique_id(), module: FakeTranslator, version: "test"})

    assert Registry.fetch(id) == {:ok, FakeTranslator}
    assert Registry.fetch("missing_#{System.unique_integer([:positive])}") == :error

    assert Enum.any?(Registry.list_translators(), fn t ->
             t.id == id and t.module == FakeTranslator and t.version == "test"
           end)
  end

  test "derives id from the module when the spec omits it" do
    id = "fake_#{System.unique_integer([:positive])}"
    register_and_cleanup!(%{module: FakeTranslator, id: id})
  end

  test "rejects duplicate ids" do
    id = unique_id()
    assert Registry.register(%{id: id, module: FakeTranslator}) == :ok
    assert Registry.register(%{id: id, module: FakeTranslator}) == {:error, :already_registered}
    Registry.unregister(id)
  end

  test "rejects modules with a mismatched adapter_api" do
    assert Registry.register(%{id: unique_id(), module: WrongVersionTranslator}) ==
             {:error, {:unsupported_adapter_api, 99, 1}}
  end

  test "rejects modules without id/0" do
    assert Registry.register(%{id: unique_id(), module: String}) == {:error, :not_a_translator}
    # nil is an atom but has no id/0, same as Source.Registry behaviour
    assert Registry.register(%{id: unique_id(), module: nil}) == {:error, :not_a_translator}
  end

  test "rejects invalid specs" do
    assert Registry.register(%{}) == {:error, :invalid_spec}
    # non-atom module fails normalization
    assert Registry.register(%{id: unique_id(), module: "not a module"}) ==
             {:error, :invalid_spec}

    # empty id falls back to the module's id/0 (matches Source.Registry)
    register_and_cleanup!(%{id: "", module: FakeTranslator})
  end
end
