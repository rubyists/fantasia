defmodule Stokowski do
  @moduledoc "Fantasia's native Stokowski-compatible runtime contracts."

  @version Mix.Project.config()[:version]

  @spec version() :: String.t()
  def version, do: @version
end
