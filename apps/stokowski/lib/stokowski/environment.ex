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

  @doc false
  def default_allowlist, do: @default_allow

  @doc false
  def project_allowlist, do: @project_allow

  @spec child(map(), map()) :: map()
  def child(parent, declared) do
    parent
    |> Map.take(@default_allow)
    |> Map.merge(Map.take(declared, @project_allow))
  end
end
