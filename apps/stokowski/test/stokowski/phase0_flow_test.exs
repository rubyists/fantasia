defmodule Stokowski.Phase0FlowTest do
  use ExUnit.Case, async: false

  alias Continuum.Test, as: ContinuumTest
  alias Stokowski.Phase0Flow

  setup_all do
    {:ok, _applications} = Application.ensure_all_started(:continuum)
    :ok
  end

  setup do
    ContinuumTest.reset_in_memory!()
    :ok
  end

  test "replay uses the journaled normalized graph after source input changes" do
    fixture = Path.expand("../fixtures/config/normalized-flow.yaml", __DIR__)
    assert {:ok, input} = YamlElixir.read_from_file(fixture)

    assert {:ok, run_id} = ContinuumTest.start_synchronous(Phase0Flow, input)

    assert {:ok, %{state: :completed, result: {:ok, result}}} =
             Continuum.await(run_id, 1_000)

    assert result == %{fingerprint: "sha256:fixture", states: ["investigate", "done"]}
    history = ContinuumTest.history(run_id)
    assert [%{type: :side_effect, payload: ^input}] = history

    changed = %{"fingerprint" => "changed", "states" => [%{"name" => "merge"}]}
    assert {:ok, {:ok, ^result}} = ContinuumTest.replay(Phase0Flow, changed, history)
  end
end
