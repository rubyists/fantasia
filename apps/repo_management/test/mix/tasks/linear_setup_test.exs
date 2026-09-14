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
end
