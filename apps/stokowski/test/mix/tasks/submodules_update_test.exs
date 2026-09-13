defmodule Mix.Tasks.Submodules.UpdateTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Submodules.Update

  @tag :tmp_dir
  test "fast-forwards the configured tracking branch", %{tmp_dir: repository_root} do
    checkout = prepare_submodule(repository_root, "example", "main")
    caller = self()

    git = fn args, opts ->
      send(caller, {:git, args, opts})

      case args do
        ["config" | _] ->
          {"submodule.vendor/example.path vendor/example\n" <>
             "submodule.vendor/example.branch main\n", 0}

        ["-C", ^checkout, "show-ref" | _] ->
          {"", 0}

        ["-C", ^checkout, "rev-parse" | _] ->
          {"abc123def456\n", 0}

        _ ->
          {"", 0}
      end
    end

    assert :ok = Update.run(repository_root, git)

    assert_received {:git, ["-C", ^checkout, "fetch", "origin", "main"], []}

    assert_received {:git,
                     ["-C", ^checkout, "merge-base", "--is-ancestor", "main", "origin/main"], []}

    assert_received {:git, ["-C", ^checkout, "switch", "main"], []}

    assert_received {:git,
                     ["-C", ^checkout, "branch", "--set-upstream-to", "origin/main", "main"], []}

    assert_received {:git, ["-C", ^checkout, "merge", "--ff-only", "origin/main"], []}
  end

  @tag :tmp_dir
  test "creates a missing local branch from the configured upstream", %{tmp_dir: repository_root} do
    checkout = prepare_submodule(repository_root, "example", "master")
    caller = self()

    git = fn args, opts ->
      send(caller, {:git, args, opts})

      case args do
        ["config" | _] ->
          {"submodule.vendor/example.path vendor/example\n" <>
             "submodule.vendor/example.branch master\n", 0}

        ["-C", ^checkout, "show-ref" | _] ->
          {"", 1}

        ["-C", ^checkout, "rev-parse" | _] ->
          {"def456abc123\n", 0}

        _ ->
          {"", 0}
      end
    end

    assert :ok = Update.run(repository_root, git)

    assert_received {:git,
                     [
                       "-C",
                       ^checkout,
                       "switch",
                       "--track",
                       "-c",
                       "master",
                       "origin/master"
                     ], []}
  end

  @tag :tmp_dir
  test "refuses a dirty checkout before fetching", %{tmp_dir: repository_root} do
    checkout = prepare_submodule(repository_root, "example", "main")

    git = fn args, _opts ->
      case args do
        ["config" | _] ->
          {"submodule.vendor/example.path vendor/example\n" <>
             "submodule.vendor/example.branch main\n", 0}

        ["-C", ^checkout, "status" | _] ->
          {" M lib/example.ex\n", 0}
      end
    end

    assert_raise Mix.Error, ~r/vendor\/example has uncommitted changes/, fn ->
      Update.run(repository_root, git)
    end
  end

  @tag :tmp_dir
  test "refuses a local branch that diverges from upstream", %{tmp_dir: repository_root} do
    checkout = prepare_submodule(repository_root, "example", "main")

    git = fn args, _opts ->
      case args do
        ["config" | _] ->
          {"submodule.vendor/example.path vendor/example\n" <>
             "submodule.vendor/example.branch main\n", 0}

        ["-C", ^checkout, "show-ref" | _] ->
          {"", 0}

        ["-C", ^checkout, "merge-base" | _] ->
          {"", 1}

        _ ->
          {"", 0}
      end
    end

    assert_raise Mix.Error, ~r/local commits that diverge from origin\/main/, fn ->
      Update.run(repository_root, git)
    end
  end

  defp prepare_submodule(repository_root, name, branch) do
    File.write!(
      Path.join(repository_root, ".gitmodules"),
      "[submodule \"vendor/#{name}\"]\n" <>
        "  path = vendor/#{name}\n" <>
        "  branch = #{branch}\n"
    )

    checkout = Path.join([repository_root, "vendor", name])
    File.mkdir_p!(Path.join(checkout, ".git"))
    checkout
  end
end
