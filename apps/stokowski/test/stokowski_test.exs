defmodule StokowskiTest do
  use ExUnit.Case

  test "reports the application version" do
    expected = "../../../.version.txt" |> Path.expand(__DIR__) |> File.read!() |> String.trim()
    assert Stokowski.version() == expected
  end
end
