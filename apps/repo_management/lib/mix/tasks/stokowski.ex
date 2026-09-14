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

    resolved_runners = resolve_configured_runners!(workflow, root)
    uv = executable!("uv")

    runner_executables =
      Enum.map(resolved_runners, fn {_runner, {executable, _version}} -> executable end)

    Enum.each(resolved_runners, fn {runner, {executable, version}} ->
      Mix.shell().info("Using #{String.capitalize(runner)} #{version} at #{executable}")
    end)

    lockfile = Path.join(vendor, "uv.lock")
    lockfile_existed? = File.exists?(lockfile)

    command_args = uv_args(vendor) ++ ["stokowski", workflow | args]

    {_output, status} =
      try do
        System.cmd(uv, command_args,
          cd: root,
          env: [{"PATH", prepend_path(runner_executables)}],
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
  def resolve_codex!(root) do
    resolve_runner!(root, "codex")
  end

  @doc false
  def resolve_runner!(root, runner) when runner in ["codex", "claude"] do
    expected_version = configured_runner_version!(Path.join(root, "mise.toml"), runner)
    mise = executable!("mise")

    case System.cmd(mise, ["which", runner], cd: root) do
      {output, 0} ->
        executable = String.trim(output)
        verify_runner!(runner, executable, expected_version)

      {_output, _status} ->
        Mix.raise(
          "could not resolve the repository-managed #{runner} executable; run mise install"
        )
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

  defp resolve_configured_runners!(workflow, root) do
    runner_names =
      case Workflow.read(workflow) do
        {:ok, parsed_workflow} -> Workflow.runner_values(parsed_workflow) |> Enum.uniq()
        {:error, _error} -> []
      end

    runner_names = if runner_names == [], do: ["codex"], else: runner_names

    Enum.map(runner_names, fn runner ->
      unless runner in ["codex", "claude"] do
        Mix.raise("workflow.yaml uses unsupported runner #{inspect(runner)}")
      end

      {runner, resolve_runner!(root, runner)}
    end)
  end

  defp configured_runner_version!(path, runner) do
    ensure_file!(path, "mise.toml")

    version =
      path
      |> File.read!()
      |> String.split("\n")
      |> Enum.reduce_while({false, nil}, fn line, {in_tools, found} ->
        trimmed = String.trim(line)

        cond do
          trimmed == "[tools]" ->
            {:cont, {true, found}}

          String.starts_with?(trimmed, "[") ->
            {:halt, {false, found}}

          in_tools and found == nil ->
            case Regex.run(~r/^#{Regex.escape(runner)}\s*=\s*"([^"]+)"\s*$/, trimmed,
                   capture: :all_but_first
                 ) do
              [configured] -> {:halt, {false, configured}}
              _ -> {:cont, {in_tools, found}}
            end

          true ->
            {:cont, {in_tools, found}}
        end
      end)
      |> elem(1)

    if is_binary(version) and Regex.match?(~r/^\d+\.\d+\.\d+$/, version) do
      version
    else
      Mix.raise("mise.toml [tools] table must declare an exact #{runner} version")
    end
  end

  defp verify_runner!(runner, executable, expected_version) do
    label = String.capitalize(runner)

    unless Path.type(executable) == :absolute and File.regular?(executable) do
      Mix.raise("mise resolved an invalid #{label} executable path")
    end

    case System.cmd(executable, ["--version"]) do
      {output, 0} ->
        case observed_runner_version(runner, String.trim(output)) do
          [^expected_version] -> {executable, expected_version}
          [_observed] -> Mix.raise("repository-managed #{label} version does not match mise.toml")
          _ -> Mix.raise("repository-managed #{label} returned an unrecognized version")
        end

      {_output, _status} ->
        Mix.raise("repository-managed #{label} version probe failed")
    end
  end

  defp observed_runner_version("codex", output),
    do: Regex.run(~r/^codex-cli\s+(\S+)\s*$/, output, capture: :all_but_first) || []

  defp observed_runner_version("claude", output),
    do: Regex.run(~r/(?:^|\s)(\d+\.\d+\.\d+)(?:\s|$)/, output, capture: :all_but_first) || []

  defp prepend_path(executables) do
    directories = executables |> Enum.map(&Path.dirname/1) |> Enum.uniq()
    prefix = Enum.join(directories, ":")

    case System.get_env("PATH") do
      nil -> prefix
      path -> prefix <> ":" <> path
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
