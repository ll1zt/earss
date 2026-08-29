defmodule Earss.Plugins do
  @moduledoc """
  Runtime plugin discovery and registration for optional source / translate
  (and later TTS) plugins.

  Optional plugins are Mix deps that may start *before* `:earss` and fail to
  register (the registries are not up yet). Once the registries are up,
  `register_all/1` picks up plugin modules from, in order:

    1. host config — `config :earss, <config_key>` (e.g. `:source_adapters`)
    2. explicit operator env — `<ENV_VAR>` (comma-separated module names)
    3. loaded-app convention — every loaded `earss_<prefix>_*` app maps to
       `Earss<Prefix><Suffix>` (e.g. `:earss_source_telegram` →
       `EarssSourceTelegram.Adapter`)

  Each kind declares its conventions as an `Earss.Plugins.Kind`. Registration
  is best-effort: a broken or missing plugin module must never stop the app
  from booting.
  """

  defmodule Kind do
    @moduledoc """
    Conventions for one plugin kind.

    Fields:

      * `:id` — kind atom (`:source`, `:translate`)
      * `:app_prefix` — loaded-app prefix, e.g. `"earss_source_"`
      * `:module_suffix` — convention module suffix, e.g. `"Adapter"`
      * `:env_var` — explicit-module env var, e.g. `"EARSS_SOURCE_ADAPTERS"`
      * `:config_key` — host config key, e.g. `:source_adapters`
      * `:registry` — target registry facade (e.g. `Earss.Source.Registry`)
    """
    @enforce_keys [:id, :app_prefix, :module_suffix, :env_var, :config_key, :registry]
    defstruct [:id, :app_prefix, :module_suffix, :env_var, :config_key, :registry]
  end

  @doc "Source adapter kind (`earss_source_*` apps → `EarssSource*.Adapter`)."
  @spec source() :: Kind.t()
  def source do
    %Kind{
      id: :source,
      app_prefix: "earss_source_",
      module_suffix: "Adapter",
      env_var: "EARSS_SOURCE_ADAPTERS",
      config_key: :source_adapters,
      registry: Earss.Source.Registry
    }
  end

  @doc "Translation enricher kind (`earss_translate_*` apps → `EarssTranslate*.Translator`)."
  @spec translate() :: Kind.t()
  def translate do
    %Kind{
      id: :translate,
      app_prefix: "earss_translate_",
      module_suffix: "Translator",
      env_var: "EARSS_TRANSLATE_ADAPTERS",
      config_key: :translate_adapters,
      registry: Earss.Enrichment.Registry
    }
  end

  # TTS providers (`earss_tts_*` apps → `EarssTts*.Provider`).
  @spec tts() :: Kind.t()
  def tts do
    %Kind{
      id: :tts,
      app_prefix: "earss_tts_",
      module_suffix: "Provider",
      env_var: "EARSS_TTS_PROVIDERS",
      config_key: :tts_providers,
      registry: Earss.TTS.Registry
    }
  end

  # TTS providers (`earss_tts_*` apps → `EarssTts*.Provider`) join here once
  # the TTS branch lands; the Kind struct already covers the shape.

  @doc """
  Discover plugin modules for a kind: config list, env module list, then the
  loaded-app convention. Sources may overlap; `register_all/1` uniqs.
  """
  @spec discover(Kind.t()) :: [module()]
  def discover(kind) do
    config_modules(kind) ++ env_modules(kind) ++ convention_modules(kind)
  end

  @doc """
  Register every discovered module for a kind. Best-effort: invalid or
  missing modules are skipped and never fail the caller.
  """
  @spec register_all(Kind.t()) :: :ok
  def register_all(kind) do
    kind
    |> discover()
    |> Enum.uniq()
    |> Enum.each(&register_module(kind, &1))

    :ok
  end

  @doc """
  Map a loaded app name to its conventional plugin module, e.g.
  `:earss_source_telegram` → `EarssSourceTelegram.Adapter`.
  """
  @spec convention_module(atom(), Kind.t()) :: module()
  def convention_module(app, kind) when is_atom(app) do
    Module.concat([Macro.camelize(Atom.to_string(app)), kind.module_suffix])
  end

  ## Internal

  defp config_modules(kind) do
    Application.get_env(:earss, kind.config_key, [])
  end

  defp env_modules(kind) do
    case System.get_env(kind.env_var) do
      nil ->
        []

      "" ->
        []

      raw ->
        raw
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.map(&Module.concat(String.split(&1, ".")))
        |> Enum.filter(&loaded_module?/1)
    end
  end

  defp convention_modules(kind) do
    Application.loaded_applications()
    |> Enum.map(fn {app, _desc, _vsn} -> app end)
    |> Enum.filter(fn app ->
      String.starts_with?(Atom.to_string(app), kind.app_prefix)
    end)
    |> Enum.map(&convention_module(&1, kind))
    |> Enum.filter(&loaded_module?/1)
  end

  defp loaded_module?(mod), do: match?({:module, _}, Code.ensure_loaded(mod))

  defp register_module(kind, mod) when is_atom(mod) do
    if function_exported?(mod, :id, 0) do
      _ = kind.registry.register(%{id: mod.id(), module: mod, version: "plugin"})
    end

    :ok
  rescue
    _ -> :ok
  end
end
