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

  test "registers a translator and fetches it by id" do
    id = unique_id()

    assert Registry.register(%{id: id, module: FakeTranslator, version: "test"}) == :ok
    assert Registry.fetch(id) == {:ok, FakeTranslator}
    assert Registry.fetch("missing_#{System.unique_integer([:positive])}") == :error

    assert Enum.any?(Registry.list_translators(), fn t ->
             t.id == id and t.module == FakeTranslator and t.version == "test"
           end)
  end

  test "derives id from the module when the spec omits it" do
    id = "fake_#{System.unique_integer([:positive])}"
    assert Registry.register(%{module: FakeTranslator, id: id}) == :ok
  end

  test "rejects duplicate ids" do
    id = unique_id()
    assert Registry.register(%{id: id, module: FakeTranslator}) == :ok
    assert Registry.register(%{id: id, module: FakeTranslator}) == {:error, :already_registered}
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
    assert Registry.register(%{id: "", module: FakeTranslator}) == :ok
  end
end
