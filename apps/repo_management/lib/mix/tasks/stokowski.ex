defmodule Mix.Tasks.Stokowski do
  @moduledoc """
  Launches the vendored Stokowski CLI against Fantasia's root workflow.

  Before launch, the task parses `workflow.yaml` with the native Stokowski
  workflow parser. Every `api_key` value must be an environment reference such
  as `$LINEAR_API_KEY`; literal values are rejected without being printed.
  """

  use Mix.Task

  alias Stokowski.Workflow

  @shortdoc "Runs vendored Stokowski with the root workflow"
  @environment_reference ~r/^\$[A-Za-z_][A-Za-z0-9_]*$/

  @impl Mix.Task
  def run(args) do
    run(args, umbrella_root())
  end

  @doc false
  def run(args, root) do
    workflow = Path.join(root, "workflow.yaml")
    vendor = Path.join([root, "vendor", "stokowski"])

    ensure_file!(workflow, "workflow.yaml")
    ensure_vendor!(vendor)
    validate_api_key!(workflow)

    uv = executable!("uv")
    executable!("codex")

    lockfile = Path.join(vendor, "uv.lock")
    lockfile_existed? = File.exists?(lockfile)

    command_args = uv_args(vendor) ++ ["stokowski", workflow | args]

    {_output, status} =
      try do
        System.cmd(uv, command_args,
          cd: root,
          stderr_to_stdout: true,
          into: IO.stream(:stdio, :line)
        )
      after
        unless lockfile_existed? do
          File.rm(lockfile)
        end
      end

    if status != 0 do
      Mix.raise("vendored Stokowski exited with status #{status}")
    end
  end

  @doc false
  def validate_api_key!(workflow) do
    case Workflow.read(workflow) do
      {:ok, parsed_workflow} ->
        if Enum.all?(Workflow.api_key_values(parsed_workflow), &environment_reference?/1) do
          :ok
        else
          Mix.raise(
            "workflow.yaml must not contain a literal tracker.api_key; use $LINEAR_API_KEY instead"
          )
        end

      {:error, _error} ->
        Mix.raise("could not safely parse tracker.api_key in workflow.yaml")
    end
  end

  defp environment_reference?(value) when is_binary(value),
    do: Regex.match?(@environment_reference, value)

  defp environment_reference?(_value), do: false

  defp umbrella_root do
    Path.expand("../../../../..", __DIR__)
  end

  defp ensure_file!(path, name) do
    unless File.regular?(path) do
      Mix.raise("#{name} is missing from the umbrella root: #{path}")
    end
  end

  defp ensure_vendor!(vendor) do
    unless File.regular?(Path.join(vendor, "pyproject.toml")) do
      Mix.raise(
        "vendored Stokowski is unavailable at #{vendor}; initialize submodules with git submodule update --init --recursive"
      )
    end
  end

  defp executable!(name) do
    case System.find_executable(name) do
      nil -> Mix.raise("#{name} is unavailable; run mise install and retry")
      path -> path
    end
  end

  defp uv_args(vendor) do
    [
      "run",
      "--project",
      vendor,
      "--extra",
      "web",
      "--with-editable",
      vendor,
      "--"
    ]
  end
end
