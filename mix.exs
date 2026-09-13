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
    [setup: ["deps.get", &setup_linear_cli/1, "compile"]]
  end

  defp setup_linear_cli(_args) do
    mix = System.find_executable("mix") || Mix.raise("could not find mix on PATH")
    app = Path.join([__DIR__, "vendor", "linear-cli", "app"])

    Mix.shell().info("Fetching vendored Linear CLI dependencies")

    {_output, status} =
      System.cmd(mix, ["deps.get"],
        cd: app,
        into: IO.stream(:stdio, :line),
        stderr_to_stdout: true
      )

    if status != 0 do
      Mix.raise("vendored Linear CLI dependency setup exited with status #{status}")
    end
  end
end
