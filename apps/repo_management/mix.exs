defmodule RepoManagement.MixProject do
  use Mix.Project

  @version "../../.version.txt" |> Path.expand(__DIR__) |> File.read!() |> String.trim()

  def project do
    [
      app: :repo_management,
      version: @version,
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      deps: [{:stokowski, in_umbrella: true}]
    ]
  end
end
