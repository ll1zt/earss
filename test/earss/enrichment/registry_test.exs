defmodule Earss.Enrichment.RegistryTest do
  use ExUnit.Case, async: false

  alias Earss.Enrichment.Registry

  defmodule FakeEnricher do
    @behaviour Earss.Source.Enricher

    @impl true
    def id, do: "fake"

    @impl true
    def adapter_api, do: Earss.Source.Enricher.api_version()

    @impl true
    def provider_info, do: %{name: "Fake", base_url: nil, model: nil}

    @impl true
    def enrich(_payloads, _opts), do: {:ok, []}
  end

  defmodule WrongVersionEnricher do
    @behaviour Earss.Source.Enricher

    @impl true
    def id, do: "wrong"

    @impl true
    def adapter_api, do: 99

    @impl true
    def provider_info, do: %{name: "Wrong"}

    @impl true
    def enrich(_payloads, _opts), do: {:ok, []}
  end

  defp unique_id, do: "fake_#{System.unique_integer([:positive])}"

  # Register with a unique id and always clean it up so the global Registry
  # never leaks fake enrichers into other test files. An empty/omitted id
  # falls back to the module's id/0 — unregister that real id.
  defp register_and_cleanup!(spec) do
    assert Registry.register(spec) == :ok

    real_id =
      if spec.id in [nil, ""], do: spec.module.id(), else: spec.id

    on_exit(fn -> Registry.unregister(real_id) end)
    real_id
  end

  test "registers a enricher and fetches it by id" do
    id = register_and_cleanup!(%{id: unique_id(), module: FakeEnricher, version: "test"})

    assert Registry.fetch(id) == {:ok, FakeEnricher}
    assert Registry.fetch("missing_#{System.unique_integer([:positive])}") == :error

    assert Enum.any?(Registry.list_enrichers(), fn t ->
             t.id == id and t.module == FakeEnricher and t.version == "test"
           end)
  end

  test "derives id from the module when the spec omits it" do
    id = "fake_#{System.unique_integer([:positive])}"
    register_and_cleanup!(%{module: FakeEnricher, id: id})
  end

  test "rejects duplicate ids" do
    id = unique_id()
    assert Registry.register(%{id: id, module: FakeEnricher}) == :ok
    assert Registry.register(%{id: id, module: FakeEnricher}) == {:error, :already_registered}
    Registry.unregister(id)
  end

  test "rejects modules with a mismatched adapter_api" do
    assert Registry.register(%{id: unique_id(), module: WrongVersionEnricher}) ==
             {:error, {:unsupported_adapter_api, 99, 1}}
  end

  test "rejects modules without id/0" do
    assert Registry.register(%{id: unique_id(), module: String}) == {:error, :not_an_enricher}
    # nil is an atom but has no id/0, same as Source.Registry behaviour
    assert Registry.register(%{id: unique_id(), module: nil}) == {:error, :not_an_enricher}
  end

  test "rejects invalid specs" do
    assert Registry.register(%{}) == {:error, :invalid_spec}
    # non-atom module fails normalization
    assert Registry.register(%{id: unique_id(), module: "not a module"}) ==
             {:error, :invalid_spec}

    # empty id falls back to the module's id/0 (matches Source.Registry)
    register_and_cleanup!(%{id: "", module: FakeEnricher})
  end
end
