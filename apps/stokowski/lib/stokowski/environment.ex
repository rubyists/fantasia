defmodule Stokowski.Environment do
  @moduledoc "Constructs the explicit child-process environment boundary."

  @default_allow ~w(HOME LANG LC_ALL PATH SHELL SSH_AUTH_SOCK TERM TMPDIR USER)
  @project_allow ~w(
    LINEAR_API_KEY
    LINEAR_ENDPOINT
    LINEAR_PROJECT_SLUG
    STOKOWSKI_PROJECT
    STOKOWSKI_ARTIFACTS
    STOKOWSKI_ISSUE
    STOKOWSKI_STATE
  )

  @spec child(map(), map(), [String.t()]) :: map()
  def child(parent, declared, allow \\ @default_allow) do
    parent
    |> Map.take(allow)
    |> Map.merge(Map.take(declared, @project_allow))
  end
end
