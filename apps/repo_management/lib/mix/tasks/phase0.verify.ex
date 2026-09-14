defmodule Mix.Tasks.Phase0.Verify do
  @moduledoc """
  Validates Phase 0 evidence and smoke-tests the packaged version command.
  """

  use Mix.Task

  @shortdoc "Validates Phase 0 contracts and artifact smoke"

  @impl Mix.Task
  def run(_args) do
    root = umbrella_root()
    ledger = Path.join(root, "apps/stokowski/test/fixtures/compatibility_ledger.yaml")

    case Stokowski.Compatibility.validate(ledger, root) do
      :ok -> :ok
      {:error, reason} -> Mix.raise("invalid Phase 0 compatibility ledger: #{inspect(reason)}")
    end

    artifact = Path.join(root, "fantasia")

    try do
      build_escript!(root)
      smoke_escript!(artifact)
    after
      File.rm(artifact)
    end

    Mix.shell().info("Phase 0 compatibility and artifact verification passed")
  end

  defp build_escript!(root) do
    mix = System.find_executable("mix") || Mix.raise("mix executable is unavailable")

    case System.cmd(mix, ["escript.build"],
           cd: Path.join(root, "apps/stokowski"),
           env: [{"MIX_ENV", "prod"}],
           stderr_to_stdout: true
         ) do
      {_output, 0} -> :ok
      {output, _status} -> Mix.raise("could not build fantasia escript:\n#{output}")
    end
  end

  defp smoke_escript!(source) do
    smoke_dir =
      Path.join(System.tmp_dir!(), "fantasia-phase0-#{System.unique_integer([:positive])}")

    artifact = Path.join(smoke_dir, "fantasia")

    File.mkdir_p!(smoke_dir)

    try do
      File.cp!(source, artifact)
      File.chmod!(artifact, 0o755)

      case System.cmd(artifact, ["version"], cd: smoke_dir, stderr_to_stdout: true) do
        {"fantasia 0.1.0\n", 0} -> :ok
        {_output, _status} -> Mix.raise("packaged fantasia version smoke failed")
      end
    after
      File.rm_rf!(smoke_dir)
    end
  end

  defp umbrella_root, do: Path.expand("../../../../..", __DIR__)
end
