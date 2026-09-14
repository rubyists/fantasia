defmodule Stokowski.CLITest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  test "reports the canonical version" do
    expected = "../../../../.version.txt" |> Path.expand(__DIR__) |> File.read!() |> String.trim()
    assert capture_io(fn -> Stokowski.CLI.main(["version"]) end) == "fantasia #{expected}\n"
  end
end
