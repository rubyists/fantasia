defmodule Stokowski.Environment do
  @moduledoc "Constructs the explicit child-process environment boundary."

  @default_allow ~w(HOME LANG LC_ALL PATH SHELL SSH_AUTH_SOCK TERM TMPDIR USER)

  @spec child(map(), map(), [String.t()]) :: map()
  def child(parent, declared, allow \\ @default_allow) do
    parent
    |> Map.take(allow)
    |> Map.merge(declared)
  end
end
