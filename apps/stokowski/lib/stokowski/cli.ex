defmodule Stokowski.CLI do
  @moduledoc false

  def main(["version"]), do: IO.puts("fantasia #{Stokowski.version()}")

  def main(_args) do
    IO.puts(:stderr, "usage: fantasia version")
    System.halt(2)
  end
end
