defmodule Fantasia.MixProject do
  use Mix.Project

  @version ".version.txt" |> File.read!() |> String.trim()

  def project do
    [
      apps_path: "apps",
      version: @version,
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
    [setup: ["deps.get", "compile", "linear.setup"]]
  end
end
