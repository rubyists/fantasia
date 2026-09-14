defmodule Stokowski.CLITest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  test "reports the canonical version" do
    assert capture_io(fn -> Stokowski.CLI.main(["version"]) end) == "fantasia 0.1.0\n"
  end
end
