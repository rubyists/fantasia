defmodule Stokowski.MixProject do
  use Mix.Project

  @version "../../.version.txt" |> Path.expand(__DIR__) |> File.read!() |> String.trim()

  def project do
    [
      app: :stokowski,
      version: @version,
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      escript: [
        main_module: Stokowski.CLI,
        name: "fantasia",
        path: System.get_env("FANTASIA_ESCRIPT_PATH", "../../fantasia")
      ],
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:continuum, path: "../../vendor/Continuum"},
      {:jason, "~> 1.4"},
      {:yaml_elixir, "~> 2.12"}
    ]
  end
end
