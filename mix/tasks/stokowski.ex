defmodule Mix.Tasks.Stokowski do
  @moduledoc """
  Launches the vendored Stokowski CLI against Fantasia's root workflow.
  """

  use Mix.Task

  @shortdoc "Runs vendored Stokowski with the root workflow"

  @impl Mix.Task
  def run(args) do
    root = umbrella_root()
    workflow = Path.join(root, "workflow.yaml")
    vendor = Path.join([root, "vendor", "stokowski"])

    ensure_file!(workflow, "workflow.yaml")
    ensure_vendor!(vendor)
    reject_literal_api_key!(workflow)

    uv = executable!("uv")
    executable!("codex")

    lockfile = Path.join(vendor, "uv.lock")
    lockfile_existed? = File.exists?(lockfile)

    command_args = [
      "run",
      "--project",
      vendor,
      "--extra",
      "web",
      "--with-editable",
      vendor,
      "--",
      "stokowski",
      workflow | args
    ]

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

  defp umbrella_root do
    Path.expand("../..", __DIR__)
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

  defp reject_literal_api_key!(workflow) do
    workflow
    |> File.stream!()
    |> Enum.reject(&String.starts_with?(String.trim_leading(&1), "#"))
    |> Enum.find(&literal_api_key?/1)
    |> case do
      nil ->
        :ok

      _line ->
        Mix.raise(
          "workflow.yaml must not contain a literal tracker.api_key; use $LINEAR_API_KEY instead"
        )
    end
  end

  defp literal_api_key?(line) do
    case Regex.run(~r/^\s*api_key\s*:\s*(.+?)\s*$/, line) do
      [_, value] -> not env_reference?(value)
      nil -> false
    end
  end

  defp env_reference?(value) do
    Regex.match?(~r/^['\"]?\$[A-Za-z_][A-Za-z0-9_]*['\"]?(?:\s+#.*)?$/, value)
  end
end
