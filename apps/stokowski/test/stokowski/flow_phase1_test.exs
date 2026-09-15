defmodule Stokowski.FlowPhase1Test do
  use ExUnit.Case, async: false

  alias Continuum.Test, as: ContinuumTest
  alias Stokowski.Domain

  setup_all do
    {:ok, _applications} = Application.ensure_all_started(:continuum)
    :ok
  end

  setup do
    ContinuumTest.reset_in_memory!()
    :ok
  end

  test "fake eight-phase history completes and replays after caller input changes" do
    {:ok, snapshot} =
      Stokowski.Config.load(Path.expand("../../priv/examples/default/workflow.yaml", __DIR__))

    events = [
      Domain.agent_completed(),
      Domain.approve(),
      Domain.agent_completed(),
      Domain.approve(),
      Domain.agent_completed(),
      Domain.approve(),
      Domain.agent_completed()
    ]

    {:ok, run_id} =
      ContinuumTest.start_synchronous(Stokowski.Flow, %{snapshot: snapshot, events: events})

    assert {:ok, %{state: :completed, result: {:ok, %{state: %{phase: "done"}}}}} =
             Continuum.await(run_id, 1_000)

    history = ContinuumTest.history(run_id)
    assert hd(history).type == :side_effect
    assert Enum.count(history, &(&1.type == :activity_completed)) == 7

    changed = %{snapshot: %{fingerprint: "changed"}, events: [Domain.failed(:changed)]}

    assert {:ok, {:ok, %{state: %{phase: "done"}}}} =
             ContinuumTest.replay(Stokowski.Flow, changed, history)
  end

  test "terminal signal cancels a non-terminal flow without selecting an edge" do
    {:ok, snapshot} =
      Stokowski.Config.load(Path.expand("../../priv/examples/default/workflow.yaml", __DIR__))

    {:ok, run_id} =
      ContinuumTest.start_synchronous(Stokowski.Flow, %{
        snapshot: snapshot,
        events: [Domain.terminal(:external)]
      })

    assert {:ok,
            %{
              state: :completed,
              result: {:ok, %{state: %{status: :cancelled, phase: "investigate"}}}
            }} = Continuum.await(run_id, 1_000)
  end

  test "committed histories cover the deterministic terminal outcomes" do
    expected = %{
      "default-eight-phase" => {:completed, "done", 1},
      "straight-through" => {:completed, "done", 1},
      "approval" => {:completed, "done", 1},
      "rework" => {:completed, "done", 2},
      "escalation" => {:escalated, "review", 3},
      "external-terminal" => {:cancelled, "work", 1}
    }

    for {name, {status, phase, run}} <- expected do
      history =
        Path.join(Path.expand("../fixtures/histories", __DIR__), name <> ".term")
        |> Continuum.Test.load_history!()

      changed = %{snapshot: %{fingerprint: "caller-change"}, events: [Domain.failed(:ignored)]}

      assert {:ok, {:ok, %{state: %Domain.PhaseState{status: ^status, phase: ^phase, run: ^run}}}} =
               Continuum.Test.replay(Stokowski.Flow, changed, history)
    end
  end
end
