defmodule Earss.MixProject do
  use Mix.Project

  def project do
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
      {:earss_source, path: "packages/earss_source"},
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

  # Site plugins are optional. Core never requires them for tests or stock deploys.
  #
  # Enable Telegram public-channel adapter (earss://telegram/channel/<username>):
  #
  #   EARSS_TELEGRAM_PLUGIN=1 mix deps.get
  #   # or pin GitHub:
  #   EARSS_TELEGRAM_PLUGIN=git mix deps.get
  #
  # See docs/sources.md § "Operator: optional plugins".
  defp optional_source_plugins do
    case System.get_env("EARSS_TELEGRAM_PLUGIN") do
      v when v in ["1", "true", "path"] ->
        [{:earss_source_telegram, path: "../earss_source_telegram"}]

      "git" ->
        [
          {:earss_source_telegram,
           github: "ll1zt/earss_source_telegram", branch: "main"}
        ]

      _ ->
        []
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
