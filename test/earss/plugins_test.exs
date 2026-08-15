defmodule Earss.PluginsTest do
  use ExUnit.Case, async: false

  alias Earss.Plugins

  defmodule TestAdapter do
    def id, do: "plugins_test_adapter"
    def adapter_api, do: Earss.Source.Adapter.api_version()
    def routes, do: [%{path: "/test", label: "Test"}]
  end

  defmodule TestEnricher do
    def id, do: "plugins_test_enricher"
    def adapter_api, do: Earss.Source.Enricher.api_version()
    def provider_info, do: %{name: "Test"}
    def enrich(_payloads, _opts), do: {:ok, []}
  end

  setup do
    on_exit(fn ->
      System.delete_env("EARSS_SOURCE_ADAPTERS")
      System.delete_env("EARSS_TRANSLATE_ADAPTERS")
      Application.delete_env(:earss, :source_adapters)
      Application.delete_env(:earss, :translate_adapters)

      Earss.Registry.unregister(Earss.Registry.Source, TestAdapter.id())
      Earss.Enrichment.Registry.unregister(TestEnricher.id())
    end)

    :ok
  end

  test "convention_module maps a loaded app to its plugin module" do
    assert Plugins.convention_module(:earss_source_telegram, Plugins.source()) ==
             EarssSourceTelegram.Adapter

    assert Plugins.convention_module(:earss_translate_openai, Plugins.translate()) ==
             EarssTranslateOpenai.Translator
  end

  test "register_all registers explicit env modules" do
    System.put_env("EARSS_SOURCE_ADAPTERS", "Earss.PluginsTest.TestAdapter")

    assert :ok = Plugins.register_all(Plugins.source())
    assert {:ok, TestAdapter} = Earss.Source.Registry.fetch(TestAdapter.id())
  end

  test "register_all registers host config modules" do
    Application.put_env(:earss, :source_adapters, [TestAdapter])

    assert :ok = Plugins.register_all(Plugins.source())
    assert {:ok, TestAdapter} = Earss.Source.Registry.fetch(TestAdapter.id())
  end

  test "register_all is idempotent" do
    System.put_env("EARSS_SOURCE_ADAPTERS", "Earss.PluginsTest.TestAdapter")

    assert :ok = Plugins.register_all(Plugins.source())
    assert :ok = Plugins.register_all(Plugins.source())
    assert {:ok, TestAdapter} = Earss.Source.Registry.fetch(TestAdapter.id())
  end

  test "register_all tolerates missing modules" do
    System.put_env("EARSS_SOURCE_ADAPTERS", "No.Such.Module,Earss.PluginsTest.TestAdapter")

    assert :ok = Plugins.register_all(Plugins.source())
    assert {:ok, TestAdapter} = Earss.Source.Registry.fetch(TestAdapter.id())
  end

  test "translate kind registers into the enrichment registry" do
    System.put_env("EARSS_TRANSLATE_ADAPTERS", "Earss.PluginsTest.TestEnricher")

    assert :ok = Plugins.register_all(Plugins.translate())
    assert {:ok, TestEnricher} = Earss.Enrichment.Registry.fetch(TestEnricher.id())
  end

  test "discover combines config, env and convention sources" do
    Application.put_env(:earss, :source_adapters, [TestAdapter])
    System.put_env("EARSS_SOURCE_ADAPTERS", "Earss.PluginsTest.TestAdapter")

    mods = Plugins.discover(Plugins.source())
    assert TestAdapter in mods
  end
end
