defmodule Mix.Tasks.Lc do
  @shortdoc "Runs the vendored Linear CLI"

  @moduledoc """
  #{@shortdoc}.

      mix lc [LC_ARGS...]

  Proxies every argument and standard stream through the `mix lc` task in
  `vendor/linear-cli`. The vendored task compiles and starts its CLI application
  as needed, and its exit status is preserved.

      mix lc issue list
      mix lc issue comment ISSUE_ID --body-file PATH
  """

  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    run(argv, repository_root(), &run_child/3, &System.halt/1)
  end

  @doc false
  def run(argv, repository_root, command, halt) do
    checkout = Path.join([repository_root, "vendor", "linear-cli"])

    unless File.regular?(Path.join(checkout, "mix.exs")) do
      Mix.raise(
        "vendored Linear CLI is missing; run git submodule update --init vendor/linear-cli"
      )
    end

    opts = [
      cd: checkout,
      env: [{"MIX_QUIET", "1"}],
      stdio: :inherit
    ]

    status = command.("mix", ["lc" | argv], opts)

    if status != 0 do
      halt.(status)
    end

    :ok
  end

  @doc false
  def run_child(executable, args, opts) do
    :inherit = Keyword.fetch!(opts, :stdio)

    executable =
      System.find_executable(executable) ||
        Mix.raise("could not find #{executable} on PATH")

    port =
      Port.open(
        {:spawn_executable, executable},
        [
          # Leave the caller's streams attached so prompts and JSON output work.
          :nouse_stdio,
          :exit_status,
          args: args,
          cd: Keyword.fetch!(opts, :cd),
          env: port_env(Keyword.fetch!(opts, :env))
        ]
      )

    receive do
      {^port, {:exit_status, status}} -> status
    end
  end

  defp repository_root do
    Mix.Project.project_file()
    |> Path.dirname()
    |> Path.expand()
  end

  defp port_env(environment) do
    Enum.map(environment, fn {name, value} ->
      {String.to_charlist(name), String.to_charlist(value)}
    end)
  end
end
