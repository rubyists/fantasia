defmodule RepoManagement.MixProject do
  use Mix.Project

  def project do
    [
      app: :repo_management,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      deps: []
    ]
  end
end
