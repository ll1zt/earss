defmodule Earss.MixProject do
  use Mix.Project

  def project do
    # Load repo-local env files before deps() reads System.get_env/1.
    load_env_files()

    [
      app: :earss,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :inets, :ssl],
      mod: {Earss.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # override: true — plugins may declare their own earss_source path/git pin;
      # the host app always owns the contract package in packages/earss_source.
      {:earss_source, path: "packages/earss_source", override: true},
      {:ecto_sql, "~> 3.0"},
      {:postgrex, ">= 0.0.0"},
      {:argon2_elixir, "~> 4.0"},
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:sweet_xml, "~> 0.7"},
      {:bandit, "~> 1.0"},
      {:plug, "~> 1.16"}
    ] ++ optional_source_plugins()
  end

  # Optional Mix deps from operator env — no host-side plugin catalog.
  #
  # Prefer earss.env (auto-loaded):
  #
  #   EARSS_SOURCE_PLUGINS=github:ll1zt/earss_source_telegram@main
  #
  # Multiple (comma-separated):
  #
  #   EARSS_SOURCE_PLUGINS=github:ll1zt/earss_source_telegram@main,path:../my_plugin
  #
  # Spec grammar (each entry):
  #   [app_name|]github:owner/repo[@ref]
  #   [app_name|]git:https://host/repo.git[@ref]
  #   [app_name|]hex:package_name[@requirement]
  #   [app_name|]path:relative_or_absolute
  #
  # If app_name is omitted it is inferred (repo basename / package / path basename,
  # with "-" → "_"). Ref: 40-hex → :ref, "v…" or dotted version → :tag, else :branch.
  #
  # Operators own trust & supply chain: only pin sources you trust.
  # After changing this: mix deps.get && mix compile
  defp optional_source_plugins do
    System.get_env("EARSS_SOURCE_PLUGINS")
    |> parse_plugin_specs()
    |> Enum.map(&parse_plugin_spec/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(fn {app, _} -> app end)
  end

  defp parse_plugin_specs(nil), do: []
  defp parse_plugin_specs(""), do: []

  defp parse_plugin_specs(raw) when is_binary(raw) do
    raw
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_plugin_spec(spec) when is_binary(spec) do
    case do_parse_plugin_spec(spec) do
      {:ok, dep} ->
        dep

      {:error, reason} ->
        IO.warn("EARSS_SOURCE_PLUGINS: skip invalid spec #{inspect(spec)} (#{reason})")
        nil
    end
  end

  defp do_parse_plugin_spec(spec) do
    {app_hint, source} =
      case String.split(spec, "|", parts: 2) do
        [app, rest] -> {String.trim(app), String.trim(rest)}
        [only] -> {nil, String.trim(only)}
      end

    with {:ok, app, opts} <- parse_source(source),
         app <- normalize_app_name(app_hint || app) do
      if app == "" or not Regex.match?(~r/^[a-z][a-z0-9_]*$/, app) do
        {:error, "invalid app name #{inspect(app)}"}
      else
        {:ok, {String.to_atom(app), opts}}
      end
    end
  end

  defp parse_source("github:" <> rest) do
    {repo, ref} = split_ref(rest)

    case String.split(repo, "/", parts: 2) do
      [owner, name] when owner != "" and name != "" ->
        app = name |> Path.basename() |> dash_to_underscore()
        {:ok, app, Keyword.put(github_ref_opts(ref), :github, "#{owner}/#{name}")}

      _ ->
        {:error, "github expects owner/repo"}
    end
  end

  defp parse_source("git:" <> rest) do
    {url, ref} = split_ref(rest)

    if url == "" do
      {:error, "git expects a URL"}
    else
      app =
        url
        |> String.trim_trailing(".git")
        |> Path.basename()
        |> dash_to_underscore()

      {:ok, app, Keyword.put(github_ref_opts(ref), :git, url)}
    end
  end

  defp parse_source("hex:" <> rest) do
    {name, req} = split_ref(rest)
    name = String.trim(name)

    cond do
      name == "" ->
        {:error, "hex expects a package name"}

      req in [nil, ""] ->
        {:ok, dash_to_underscore(name), ">= 0.0.0"}

      true ->
        {:ok, dash_to_underscore(name), req}
    end
  end

  defp parse_source("path:" <> path) do
    path = String.trim(path)

    if path == "" do
      {:error, "path expects a filesystem path"}
    else
      app = path |> Path.basename() |> dash_to_underscore()
      {:ok, app, path: path}
    end
  end

  defp parse_source(other), do: {:error, "unknown scheme in #{inspect(other)}"}

  defp split_ref(s) do
    case String.split(s, "@", parts: 2) do
      [left, right] -> {String.trim(left), String.trim(right)}
      [left] -> {String.trim(left), nil}
    end
  end

  defp github_ref_opts(nil), do: [branch: "main"]
  defp github_ref_opts(""), do: [branch: "main"]

  defp github_ref_opts(ref) do
    cond do
      Regex.match?(~r/^[0-9a-f]{7,40}$/i, ref) -> [ref: ref]
      String.starts_with?(ref, "v") -> [tag: ref]
      Regex.match?(~r/^\d+\.\d+/, ref) -> [tag: ref]
      true -> [branch: ref]
    end
  end

  defp dash_to_underscore(name), do: String.replace(name, "-", "_")

  defp normalize_app_name(name) when is_binary(name) do
    name
    |> String.trim()
    |> String.downcase()
    |> dash_to_underscore()
  end

  # Loads KEY=VALUE lines from earss.env / earss.env.local into the process env.
  # Already-set variables (shell / CI / Docker) win and are not overwritten.
  defp load_env_files do
    Enum.each(["earss.env", "earss.env.local"], &load_env_file/1)
  end

  defp load_env_file(path) do
    if File.exists?(path) do
      path
      |> File.stream!()
      |> Stream.map(&String.trim/1)
      |> Stream.reject(&(&1 == "" or String.starts_with?(&1, "#")))
      |> Enum.each(&put_env_line/1)
    end
  end

  defp put_env_line(line) do
    case String.split(line, "=", parts: 2) do
      [key, value] ->
        key = String.trim(key)
        value = value |> String.trim() |> unwrap_quotes()

        if key != "" and System.get_env(key) in [nil, ""] do
          System.put_env(key, value)
        end

      _ ->
        :ok
    end
  end

  defp unwrap_quotes(value) do
    cond do
      String.length(value) >= 2 and String.starts_with?(value, "\"") and
          String.ends_with?(value, "\"") ->
        String.slice(value, 1..-2//1)

      String.length(value) >= 2 and String.starts_with?(value, "'") and
          String.ends_with?(value, "'") ->
        String.slice(value, 1..-2//1)

      true ->
        value
    end
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]
    ]
  end
end
