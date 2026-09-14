defmodule Stokowski.Phase0Flow do
  @moduledoc """
  Minimal Continuum proof that journals normalized workflow input before use.

  It is evidence for the Phase 1 flow, not the production orchestrator.
  """

  use Continuum.Workflow, version: 1

  def run(input) do
    snapshot = Continuum.side_effect(fn -> input end)

    {:ok,
     %{
       fingerprint: snapshot["fingerprint"],
       states: Enum.map(snapshot["states"], & &1["name"])
     }}
  end
end
