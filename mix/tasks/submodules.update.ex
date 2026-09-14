defmodule Mix.Tasks.Submodules.Update do
  @shortdoc "Fast-forwards vendored submodules to their tracked branches"

  @moduledoc """
  #{@shortdoc}.

      mix submodules.update

  Branches come from `.gitmodules`. Each initialized checkout must be clean and
  have no commits that diverge from its upstream `main` or `master` branch. The
  task leaves every submodule on an attached local branch that tracks upstream.
  """

  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    if argv != [] do
      Mix.raise("mix submodules.update does not accept arguments")
    end

    run(repository_root(), &git/2)
  end

  @doc false
  def run(repository_root, git) do
    gitmodules = Path.join(repository_root, ".gitmodules")

    unless File.regular?(gitmodules) do
      Mix.raise("could not find #{gitmodules}")
    end

    entries =
      git
      |> read_entries(repository_root, gitmodules)
      |> validate_entries(repository_root)

    Enum.each(entries, &update_submodule(&1, git))
  end

  defp read_entries(git, repository_root, gitmodules) do
    output =
      run_git!(
        git,
        [
          "config",
          "--file",
          gitmodules,
          "--get-regexp",
          "^submodule\\..*\\.(path|branch)$"
        ],
        [cd: repository_root],
        "read .gitmodules"
      )

    output
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, fn line, entries ->
      with [key, value] <- String.split(line, ~r/\s+/, parts: 2),
           [_, name, field] <- Regex.run(~r/^submodule\.(.+)\.(path|branch)$/, key) do
        Map.update(entries, name, %{field => value}, &Map.put(&1, field, value))
      else
        _ -> Mix.raise("could not parse .gitmodules entry: #{line}")
      end
    end)
  end

  defp validate_entries(entries, repository_root) do
    vendor_root = Path.join(repository_root, "vendor") |> Path.expand()

    entries
    |> Enum.map(fn {name, entry} ->
      path = Map.get(entry, "path") || Mix.raise("submodule #{name} has no path")
      branch = Map.get(entry, "branch") || Mix.raise("submodule #{name} has no branch")
      checkout = Path.expand(path, repository_root)

      unless branch in ["main", "master"] do
        Mix.raise("submodule #{name} tracks unsupported branch #{inspect(branch)}")
      end

      unless checkout |> Path.dirname() |> Path.expand() == vendor_root do
        Mix.raise("submodule #{name} is outside vendor/: #{path}")
      end

      %{name: name, path: path, checkout: checkout, branch: branch}
    end)
    |> Enum.sort_by(& &1.path)
  end

  defp update_submodule(submodule, git) do
    %{name: name, path: path, checkout: checkout, branch: branch} = submodule

    unless File.exists?(Path.join(checkout, ".git")) do
      Mix.raise("submodule #{path} is not initialized; run git submodule update --init #{path}")
    end

    dirty =
      run_git!(
        git,
        ["-C", checkout, "status", "--porcelain", "--untracked-files=all"],
        [],
        "inspect #{path}"
      )

    if String.trim(dirty) != "" do
      Mix.raise("submodule #{path} has uncommitted changes")
    end

    run_git!(git, ["-C", checkout, "fetch", "origin", branch], [], "fetch #{path}")
    ensure_ancestor!(submodule, "HEAD", git)

    case git.(["-C", checkout, "show-ref", "--verify", "--quiet", "refs/heads/#{branch}"], []) do
      {_output, 0} ->
        fast_forward_branch(submodule, git)

      {_output, 1} ->
        run_git!(
          git,
          ["-C", checkout, "switch", "--track", "-c", branch, "origin/#{branch}"],
          [],
          "create #{branch} in #{path}"
        )

      {output, status} ->
        raise_git_error("inspect branch #{branch} in #{path}", output, status)
    end

    revision =
      run_git!(git, ["-C", checkout, "rev-parse", "--short=12", "HEAD"], [], "inspect #{path}")
      |> String.trim()

    Mix.shell().info("#{name}: #{branch} at #{revision}")
  end

  defp fast_forward_branch(submodule, git) do
    %{path: path, checkout: checkout, branch: branch} = submodule
    ensure_ancestor!(submodule, branch, git)

    run_git!(git, ["-C", checkout, "switch", branch], [], "switch #{path} to #{branch}")

    run_git!(
      git,
      ["-C", checkout, "branch", "--set-upstream-to", "origin/#{branch}", branch],
      [],
      "track origin/#{branch} in #{path}"
    )

    run_git!(
      git,
      ["-C", checkout, "merge", "--ff-only", "origin/#{branch}"],
      [],
      "fast-forward #{path}"
    )
  end

  defp ensure_ancestor!(%{path: path, checkout: checkout, branch: branch}, revision, git) do
    case git.(["-C", checkout, "merge-base", "--is-ancestor", revision, "origin/#{branch}"], []) do
      {_output, 0} ->
        :ok

      {_output, 1} ->
        Mix.raise(
          "submodule #{path} has local commits that diverge from origin/#{branch} (#{revision})"
        )

      {output, status} ->
        raise_git_error("compare #{path} with origin/#{branch}", output, status)
    end
  end

  defp run_git!(git, args, opts, action) do
    case git.(args, opts) do
      {output, 0} -> output
      {output, status} -> raise_git_error(action, output, status)
    end
  end

  defp raise_git_error(action, output, status) do
    detail = String.trim(output)
    message = if detail == "", do: action, else: "#{action}: #{detail}"
    Mix.raise("#{message} (git exited with status #{status})")
  end

  defp git(args, opts) do
    System.cmd("git", args, Keyword.put(opts, :stderr_to_stdout, true))
  end

  defp repository_root do
    Mix.Project.project_file()
    |> Path.dirname()
    |> Path.expand()
  end
end
