defmodule Mix.Tasks.Linear.Setup do
  @moduledoc """
  Fetches dependencies for the vendored Linear CLI application.
  """

  use Mix.Task

  @shortdoc "Fetches vendored Linear CLI dependencies"

  @impl Mix.Task
  def run(args) do
    if args != [] do
      Mix.raise("mix linear.setup does not accept arguments")
    end

    root = repository_root()
    app = Path.join([root, "vendor", "linear-cli", "app"])

    unless File.regular?(Path.join(app, "mix.exs")) do
      Mix.raise(
        "vendored Linear CLI is missing; run git submodule update --init vendor/linear-cli"
      )
    end

    mix = System.find_executable("mix") || Mix.raise("could not find mix on PATH")

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

    :ok
  end

  defp repository_root do
    Path.expand("../../../../..", __DIR__)
  end
end
