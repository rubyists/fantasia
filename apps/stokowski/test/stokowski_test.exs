defmodule StokowskiTest do
  use ExUnit.Case

  test "reports the application version" do
    assert Stokowski.version() == "0.1.0"
  end
end
