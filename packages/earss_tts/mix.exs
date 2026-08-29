defmodule EarssTts.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :earss_tts,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Stable TTS-provider contract for Earss plugins",
      package: package()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps, do: []

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/ll1zt/earss"}
    ]
  end
end
