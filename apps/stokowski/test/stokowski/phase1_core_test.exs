defmodule Stokowski.Phase1CoreTest do
  use ExUnit.Case, async: false

  alias Stokowski.{Config, Domain, PhaseMachine, Prompt, Report, Tracking}

  setup do
    Continuum.Test.reset_in_memory!()
    :ok
  end

  test "the package-owned default is the complete eight-phase graph" do
    path = Path.expand("../../priv/examples/default/workflow.yaml", __DIR__)
    assert {:ok, snapshot} = Config.load(path)
    assert map_size(snapshot.graph) == 8
    assert snapshot.entry_phase == "investigate"
    assert snapshot.graph["investigate"].prompt =~ "current phase"
    assert Config.validate(snapshot) == :ok
  end

  test "ordered routing and resolved prompts are included in the fingerprint" do
    yaml = """
    project_name: example
    routing:
      default: feature
      rules:
        - {label: bug, workflow: bug}
        - {label: spike, workflow: exploration}
    workflows:
      feature:
        prompts: {global_prompt: [global, extra]}
        states:
          work: {type: agent, prompt: phase, transitions: {complete: done}}
          done: {type: terminal}
      bug:
        prompts: {global_prompt: global}
        states:
          reproduce: {type: agent, prompt: phase, transitions: {complete: done}}
          done: {type: terminal}
      exploration:
        prompts: {global_prompt: global}
        states:
          explore: {type: agent, prompt: phase, transitions: {complete: done}}
          done: {type: terminal}
    """

    provided = %{"global" => "global", "extra" => "extra", "phase" => "phase one"}
    assert {:ok, bug} = Config.from_yaml(yaml, labels: ["  BUG  "], prompt_contents: provided)
    assert bug.workflow == "bug"
    assert bug.routing.label == "bug"
    assert bug.graph["reproduce"].prompt == "phase one"
    assert bug.prompts.global == ["global"]

    assert {:ok, feature} = Config.from_yaml(yaml, labels: [], prompt_contents: provided)
    refute bug.fingerprint == feature.fingerprint
  end

  test "legacy markdown preserves the body but rejects prose-only transitions" do
    markdown = """
    ---
    tracker:
      kind: linear
    ---
    This is the historical prompt.
    """

    assert {:ok, _raw, body} = Stokowski.Config.Loader.parse(markdown)
    assert body =~ "historical prompt"
    assert {:error, {:legacy_migration_required, message}} = Stokowski.Config.from_yaml(markdown)
    assert message =~ "deterministic phase graph"
  end

  test "the reducer accepts only typed events and emits stable ordered effects" do
    snapshot = snapshot()
    state = PhaseMachine.initial(snapshot)

    assert {:ok, gate, [%Domain.RequiredEffect{kind: :dispatch}]} =
             PhaseMachine.reduce(snapshot, state, Domain.agent_completed())

    assert gate.phase == "review"
    assert gate.attempt == 1

    assert {:ok, done, [%Domain.RequiredEffect{kind: :complete}]} =
             PhaseMachine.reduce(snapshot, gate, Domain.approve())

    assert done.status == :completed

    assert {:ok, same, [%Domain.RequiredEffect{kind: :report_failure}]} =
             PhaseMachine.reduce(
               snapshot,
               state,
               Domain.failed(%Domain.Failure{class: :runner, reason: :boom})
             )

    assert same.phase == state.phase

    assert {:error, {:invalid_event, :approve, :agent}} =
             PhaseMachine.reduce(snapshot, state, Domain.approve())

    assert PhaseMachine.dispatch_effect(snapshot, state).id ==
             PhaseMachine.dispatch_effect(snapshot, state).id

    assert {:ok, cancelled, [%Domain.RequiredEffect{kind: :cancel}]} =
             PhaseMachine.reduce(snapshot, state, Domain.terminal(:closed))

    assert cancelled.status == :cancelled
  end

  test "gate rework increments run and escalates at the configured ceiling" do
    snapshot = snapshot()
    gate = %Domain.PhaseState{phase: "review", run: 1, attempt: 2, status: :waiting}
    assert {:ok, work, effects} = PhaseMachine.reduce(snapshot, gate, Domain.rework("fix this"))
    assert work.phase == "work"
    assert work.run == 2
    assert work.rework_counts == %{"review" => 1}
    assert Enum.map(effects, & &1.kind) == [:rework, :dispatch]

    assert {:ok, work_again, _effects} =
             PhaseMachine.reduce(
               snapshot,
               %{work | phase: "review", status: :waiting},
               Domain.rework("again")
             )

    assert work_again.run == 3
    assert work_again.rework_counts == %{"review" => 2}

    ceiling = %{work_again | phase: "review", status: :waiting}

    assert {:ok, escalated, [%Domain.RequiredEffect{kind: :escalate}]} =
             PhaseMachine.reduce(snapshot, ceiling, Domain.rework("third time"))

    assert escalated.status == :escalated
  end

  test "rework budgets are independent per gate and zero means no rework" do
    snapshot = snapshot()
    other_gate = %{snapshot.graph["review"] | name: "other-review", max_rework: 1}
    snapshot = %{snapshot | graph: Map.put(snapshot.graph, "other-review", other_gate)}

    state = %Domain.PhaseState{
      phase: "review",
      run: 8,
      status: :waiting,
      rework_counts: %{"other-review" => 1}
    }

    assert {:ok, next, _effects} =
             PhaseMachine.reduce(snapshot, state, Domain.rework("review only"))

    assert next.rework_counts == %{"other-review" => 1, "review" => 1}

    zero = %{snapshot | graph: Map.put(snapshot.graph, "review", %{other_gate | max_rework: 0})}

    assert {:ok, escalated, [%Domain.RequiredEffect{kind: :escalate}]} =
             PhaseMachine.reduce(zero, %{state | rework_counts: %{}}, Domain.rework("no retry"))

    assert escalated.status == :escalated
  end

  test "atom-keyed event maps retain their payload and support escalation" do
    assert {:ok, %Domain.GateDecision{decision: :rework, feedback: "fix", actor: "Ada"}} =
             Domain.normalize_event(%{type: "rework", feedback: "fix", actor: "Ada"})

    assert {:ok, %Domain.GateDecision{decision: :escalate}} = Domain.normalize_event(:escalate)
  end

  test "prompt rendering supports nested and flat values without code evaluation" do
    issue = %Domain.Issue{id: "i", identifier: "EXT-1", title: "Title", labels: ["Bug", "spike"]}

    template =
      "{{ issue.identifier }} {{ issue_labels | lower }} {% if issue.description %}bad{% else %}missing{% endif %}"

    assert Prompt.render(template, Prompt.context(issue)) == "EXT-1 bug, spike missing"
    refute Prompt.render("{{ File.read! }}", Prompt.context(issue)) =~ "File"
  end

  test "tracking reads both formats, orders equal timestamps stably, and writes v1 only" do
    comments = [
      %{
        "id" => "b",
        "createdAt" => "2026-01-01T00:00:01Z",
        "body" =>
          "<!-- stokowski:state {\"state\":\"old\",\"timestamp\":\"2026-01-01T00:00:00Z\"} -->"
      },
      %{
        "id" => "a",
        "createdAt" => "2026-01-01T00:00:02Z",
        "body" =>
          "<!-- fantasia:v1:state {\"schema\":1,\"state\":\"new\",\"run\":2,\"timestamp\":\"2026-01-01T00:00:00Z\"} -->"
      }
    ]

    assert {:ok, %{payload: %{"state" => "new"}}} = Tracking.latest(comments, "state")
    assert Tracking.parse_latest_tracking(comments)["state"] == "new"

    assert {:ok, marker} =
             Tracking.write_state("review", ~U[2026-01-01 00:00:00Z], "effect:1", run: 2)

    assert marker =~ "fantasia:v1:state"
    refute marker =~ "stokowski:"
    assert {:error, :timestamp_required} = Tracking.write_state("review", nil, "effect:1")
  end

  test "structured report decoding keeps unavailable fields explicit" do
    assert {:ok, report} =
             Report.decode(%{"verdict" => "complete", "claims" => [%{"claim" => "done"}]})

    assert report.verdict == "complete"
    assert report.data_sources == []
    assert Report.render(report) =~ "Complete"
  end

  test "the Continuum flow replays the journaled snapshot and supports rework and escalation" do
    snapshot = snapshot()
    input = %{snapshot: snapshot, events: [Domain.agent_completed(), Domain.approve()]}
    assert {:ok, run_id} = Continuum.Test.start_synchronous(Stokowski.Flow, input)

    assert {:ok,
            %{state: :completed, result: {:ok, %{state: %Domain.PhaseState{status: :completed}}}} =
              result} =
             Continuum.await(run_id, 1_000)

    history = Continuum.Test.history(run_id)

    changed = %{snapshot: %{snapshot | fingerprint: "changed"}, events: [Domain.failed(:ignored)]}
    expected = result.result
    assert {:ok, ^expected} = Continuum.Test.replay(Stokowski.Flow, changed, history)

    rework_input = %{
      snapshot: snapshot,
      events: [
        Domain.agent_completed(),
        Domain.rework("fix"),
        Domain.agent_completed(),
        Domain.approve()
      ]
    }

    assert {:ok, rework_id} = Continuum.Test.start_synchronous(Stokowski.Flow, rework_input)

    assert {:ok,
            %{
              state: :completed,
              result: {:ok, %{state: %Domain.PhaseState{status: :completed, run: 2}}}
            }} =
             Continuum.await(rework_id, 1_000)

    escalation = %{
      snapshot: snapshot,
      events: [
        Domain.agent_completed(),
        Domain.rework("one"),
        Domain.agent_completed(),
        Domain.rework("two"),
        Domain.agent_completed(),
        Domain.rework("three")
      ]
    }

    assert {:ok, escalation_id} = Continuum.Test.start_synchronous(Stokowski.Flow, escalation)

    assert {:ok,
            %{
              state: :completed,
              result: {:ok, %{state: %Domain.PhaseState{status: :escalated, run: 3}}}
            }} =
             Continuum.await(escalation_id, 1_000)
  end

  test "a waiting flow consumes typed terminal signals" do
    input = %{snapshot: snapshot(), events: [Domain.agent_completed()], await_signal: true}
    assert {:ok, run_id} = Continuum.Test.start_synchronous(Stokowski.Flow, input)
    assert {:error, :timeout} = Continuum.await(run_id, 100)
    assert :ok = Continuum.Test.inject_signal(run_id, :phase_event, Domain.terminal(:closed))

    assert {:ok,
            %{state: :completed, result: {:ok, %{state: %Domain.PhaseState{status: :cancelled}}}}} =
             Continuum.await(run_id, 1_000)
  end

  test "an awaiting flow continues through rework after returning to an agent" do
    input = %{
      snapshot: snapshot(),
      events: [Domain.agent_completed(), Domain.rework("fix")],
      await_signal: true
    }

    assert {:ok, run_id} = Continuum.Test.start_synchronous(Stokowski.Flow, input)
    assert {:error, :timeout} = Continuum.await(run_id, 100)
    assert :ok = Continuum.Test.inject_signal(run_id, :phase_event, Domain.agent_completed())
    assert {:error, :timeout} = Continuum.await(run_id, 100)
    assert :ok = Continuum.Test.inject_signal(run_id, :phase_event, Domain.approve())

    assert {:ok,
            %{state: :completed, result: {:ok, %{state: %Domain.PhaseState{status: :completed}}}}} =
             Continuum.await(run_id, 1_000)
  end

  defp snapshot do
    %Domain.WorkflowSnapshot{
      workflow: "test",
      entry_phase: "work",
      graph: %{
        "work" => %Domain.Phase{
          name: "work",
          type: :agent,
          prompt: "work",
          transitions: %{"complete" => "review"}
        },
        "review" => %Domain.Phase{
          name: "review",
          type: :gate,
          rework_to: "work",
          max_rework: 2,
          transitions: %{"approve" => "done"}
        },
        "done" => %Domain.Phase{name: "done", type: :terminal}
      },
      prompts: %{},
      routing: %{issue: "EXT-1"},
      schema_version: 1,
      config_version: 1,
      fingerprint: "sha256:test"
    }
  end
end
