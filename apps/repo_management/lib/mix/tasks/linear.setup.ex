defmodule Mix.Tasks.Linear.Setup do
  @moduledoc """
  Fetches dependencies for the vendored Linear CLI application.

      mix linear.setup

  `vendor/linear-cli` must be initialized first. If it is missing, run
  `git submodule update --init --recursive vendor/linear-cli` from the
  repository root.
  """

  use Mix.Task

  @shortdoc "Fetches vendored Linear CLI dependencies"

  @impl Mix.Task
  def run(args) do
    run(args, repository_root())
  end

  @doc false
  def run(args, root, runner \\ &run_deps_get/2) do
    if args != [] do
      Mix.raise("mix linear.setup does not accept arguments")
    end

    checkout = Path.join([root, "vendor", "linear-cli"])
    app = Path.join([root, "vendor", "linear-cli", "app"])

    unless File.exists?(Path.join(checkout, ".git")) do
      Mix.raise(
        "vendor/linear-cli is not initialized; run git submodule update --init --recursive vendor/linear-cli"
      )
    end

    unless File.regular?(Path.join(checkout, "mix.exs")) and
             File.regular?(Path.join(app, "mix.exs")) do
      Mix.raise(
        "vendor/linear-cli is incomplete; run git submodule update --init --recursive vendor/linear-cli"
      )
    end

    mix = System.find_executable("mix") || Mix.raise("could not find mix on PATH")

    for {label, dir} <- [
          {"vendored Linear CLI repository tasks", checkout},
          {"vendored Linear CLI application", app}
        ] do
      Mix.shell().info("Fetching #{label} dependencies")

      status = runner.(mix, dir)

      if status != 0 do
        Mix.raise("#{label} dependency setup exited with status #{status}")
      end
    end

    :ok
  end

  defp run_deps_get(mix, dir) do
    {_output, status} =
      System.cmd(mix, ["deps.get"],
        cd: dir,
        into: IO.stream(:stdio, :line),
        stderr_to_stdout: true
      )

    status
  end

  defp repository_root do
    Path.expand("../../../../..", __DIR__)
  end
end
