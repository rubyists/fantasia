defmodule Mix.Tasks.Linear.SetupTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Linear.Setup

  @tag :tmp_dir
  test "fails fast when the Linear CLI submodule is not initialized", %{tmp_dir: root} do
    File.mkdir_p!(Path.join([root, "vendor", "linear-cli"]))

    assert_raise Mix.Error,
                 ~r/git submodule update --init --recursive vendor\/linear-cli/,
                 fn ->
                   Setup.run([], root)
                 end
  end

  @tag :tmp_dir
  test "fetches dependencies for both the vendored root and app projects", %{tmp_dir: root} do
    checkout = Path.join([root, "vendor", "linear-cli"])
    app = Path.join(checkout, "app")
    File.mkdir_p!(app)
    File.write!(Path.join(checkout, ".git"), "gitdir: ../.git/modules/vendor/linear-cli\n")
    File.write!(Path.join(checkout, "mix.exs"), "defmodule RepoTasks.MixProject, do: nil\n")
    File.write!(Path.join(app, "mix.exs"), "defmodule LinearCli.MixProject, do: nil\n")

    parent = self()

    assert :ok =
             Setup.run([], root, fn mix, dir ->
               send(parent, {:deps_get, Path.basename(mix), dir})
               0
             end)

    assert_received {:deps_get, "mix", ^checkout}
    assert_received {:deps_get, "mix", ^app}
  end

  @tag :tmp_dir
  test "fails fast when root repository task dependency setup fails", %{tmp_dir: root} do
    checkout = Path.join([root, "vendor", "linear-cli"])
    app = Path.join(checkout, "app")
    File.mkdir_p!(app)
    File.write!(Path.join(checkout, ".git"), "gitdir: ../.git/modules/vendor/linear-cli\n")
    File.write!(Path.join(checkout, "mix.exs"), "defmodule RepoTasks.MixProject, do: nil\n")
    File.write!(Path.join(app, "mix.exs"), "defmodule LinearCli.MixProject, do: nil\n")

    assert_raise Mix.Error, ~r/exited with status 1/, fn ->
      Setup.run([], root, fn _mix, _dir -> 1 end)
    end
  end
end
