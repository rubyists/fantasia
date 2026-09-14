defmodule Fantasia.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  # Dependencies listed here are available only for this
  # project and cannot be accessed from applications inside
  # the apps folder.
  #
  # Run "mix help deps" for examples and options.
  defp deps do
    []
  end

  defp aliases do
    [setup: ["deps.get", "linear.setup", "compile"]]
  end
end

# Root tasks must be loaded from the mixfile so they are available before an
# umbrella child application has been compiled.
__DIR__
|> Path.join("mix/tasks/*.ex")
|> Path.wildcard()
|> Enum.each(&Code.require_file/1)
