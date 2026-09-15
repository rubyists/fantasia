defmodule Stokowski.ConfigPhase1Test do
  use ExUnit.Case, async: true

  alias Stokowski.{Config, Domain}

  @default Path.expand("../../priv/examples/default/workflow.yaml", __DIR__)

  test "the package default has eight executable phases and a terminal" do
    assert {:ok, snapshot} = Config.load(@default)
    assert snapshot.entry_phase == "investigate"
    assert map_size(snapshot.graph) == 8
    assert Enum.count(snapshot.graph, fn {_name, phase} -> phase.type == :agent end) == 4
    assert Enum.count(snapshot.graph, fn {_name, phase} -> phase.type == :gate end) == 3
    assert Enum.count(snapshot.graph, fn {_name, phase} -> phase.type == :terminal end) == 1
    assert snapshot.graph["investigate"].prompt =~ "{{ issue.identifier }}"
    assert snapshot.prompts.global != []
  end

  test "routing is ordered and case insensitive" do
    raw = %{
      "routing" => %{
        "default" => "feature",
        "rules" => [
          %{"label" => "bug", "workflow" => "bug-fix"},
          %{"label" => "spike", "workflow" => "exploration"}
        ]
      }
    }

    assert {:ok, "bug-fix", %{default: false}} = Config.route(raw, ["Spike", "BUG"])
    assert {:ok, "feature", %{default: true}} = Config.route(raw, [])
  end

  test "routing provenance does not change the resolved workflow fingerprint" do
    yaml = """
    routing:
      default: feature
      rules:
        - {label: bug, workflow: feature}
    workflows:
      feature:
        states:
          work: {type: agent, prompt: phase.md, transitions: {complete: done}}
          done: {type: terminal}
    """

    opts = [prompt_contents: %{"phase.md" => "phase"}]
    assert {:ok, routed} = Config.from_yaml(yaml, Keyword.put(opts, :labels, ["bug"]))
    assert {:ok, explicit} = Config.from_yaml(yaml, Keyword.put(opts, :workflow, "feature"))
    assert routed.graph == explicit.graph
    assert routed.routing != explicit.routing
    assert routed.fingerprint == explicit.fingerprint
  end

  test "reports the routed workflow name when a route is undefined" do
    yaml = """
    routing:
      default: missing
    workflows:
      defined:
        states:
          work: {type: agent, prompt: phase.md, transitions: {complete: done}}
          done: {type: terminal}
    """

    assert {:error, {:unknown_workflow, "missing"}} =
             Config.from_yaml(yaml, prompt_contents: %{"phase.md" => "phase"})
  end

  test "loader metadata preserves declaration order for named inline workflows" do
    yaml = """
    routing: {default: custom}
    workflows:
      custom:
        states:
          done: {type: terminal}
          work: {type: agent, prompt: phase.md, transitions: {complete: done}}
    """

    assert {:ok, raw, ""} = Config.Loader.parse(yaml)
    assert raw["__workflow_phase_orders__"]["custom"] == ["done", "work"]
    assert {:ok, snapshot} = Config.from_yaml(yaml, prompt_contents: %{"phase.md" => "phase"})
    assert map_size(snapshot.graph) == 2
    refute Map.has_key?(snapshot.graph, "__phase_order__")
  end

  @tag :tmp_dir
  test "rejects prompt paths outside the workflow directory", %{tmp_dir: tmp_dir} do
    yaml = """
    states:
      work: {type: agent, prompt: ../outside.md, transitions: {complete: done}}
      done: {type: terminal}
    """

    assert {:error, {:prompt_path_outside_workflow, "../outside.md"}} =
             Config.from_yaml(yaml, workflow_dir: Path.join(tmp_dir, "workflow"))
  end

  @tag :tmp_dir
  test "preserves external declaration order without treating loader metadata as a phase",
       %{tmp_dir: tmp_dir} do
    workflow = Path.join(tmp_dir, "workflow.yaml")
    external_dir = Path.join(tmp_dir, "workflows")
    File.mkdir_p!(external_dir)
    File.write!(Path.join(tmp_dir, "prompt.md"), "phase")

    File.write!(
      Path.join(external_dir, "ordered.yaml"),
      """
      done: {type: terminal}
      work: {type: agent, prompt: prompt.md, transitions: {complete: done}}
      """
    )

    File.write!(workflow, "routing: {default: ordered}\n")

    assert {:ok, raw, ""} = Config.Loader.read(Path.join(external_dir, "ordered.yaml"))
    assert raw["__phase_order__"] == ["done", "work"]
    assert {:ok, snapshot} = Config.load(workflow)
    assert map_size(snapshot.graph) == 2
    refute Map.has_key?(snapshot.graph, "__phase_order__")
  end

  test "specialized examples keep grounding as a fresh data-defined phase" do
    for kind <- ["bug-fix", "feature", "exploration"] do
      path = Path.expand("../../priv/examples/#{kind}/workflow.yaml", __DIR__)
      assert {:ok, snapshot} = Config.load(path)
      assert {:ok, _ground_check} = Map.fetch(snapshot.graph, "ground-check")
      assert snapshot.graph["ground-check"].session == :fresh
      assert snapshot.prompts.global |> length() == 2
    end
  end

  test "fingerprints include resolved prompts but exclude tracker credentials" do
    base = """
    project_name: example
    tracker:
      api_key: literal-secret
    prompts:
      global_prompt: global.md
    states:
      start:
        type: agent
        prompt: phase.md
        transitions: {complete: done}
      done:
        type: terminal
    """

    opts = [prompt_contents: %{"global.md" => "global one", "phase.md" => "phase one"}]
    assert {:ok, first} = Config.from_yaml(base, opts)
    assert first.fingerprint == Config.fingerprint(first)
    refute first.fingerprint =~ "secret"

    assert {:ok, changed} =
             Config.from_yaml(
               base,
               Keyword.put(opts, :prompt_contents, %{
                 "global.md" => "global two",
                 "phase.md" => "phase one"
               })
             )

    refute first.fingerprint == changed.fingerprint
  end

  test "preserves a zero rework limit in the normalized phase" do
    yaml = """
    states:
      work: {type: agent, prompt: phase.md, transitions: {complete: review}}
      review:
        type: gate
        rework_to: work
        max_rework: 0
        transitions: {approve: done}
      done: {type: terminal}
    """

    assert {:ok, snapshot} = Config.from_yaml(yaml, prompt_contents: %{"phase.md" => "phase"})
    assert snapshot.graph["review"].max_rework == 0
  end

  test "legacy markdown without a graph gives a migration diagnostic" do
    assert {:error, {:legacy_migration_required, message}} =
             Config.from_yaml("---\nproject_name: old\n---\nA free-form workflow")

    assert message =~ "deterministic phase graph"
  end

  test "phase reducer distinguishes run rework from attempt number" do
    {:ok, snapshot} = Config.load(@default)
    state = %Domain.PhaseState{phase: "research-review", run: 1, attempt: 4, status: :waiting}

    assert {:ok, next, [_rework_effect, effect]} =
             Stokowski.PhaseMachine.reduce(snapshot, state, Domain.rework("missing test"),
               project: "p",
               issue: "i"
             )

    assert next.phase == "investigate"
    assert next.run == 2
    assert next.attempt == 1
    assert effect.kind == :dispatch
    assert effect.attempt.phase == "investigate"
    assert effect.attempt.run == 2
    assert effect.attempt.attempt == 1
  end

  test "failures and prose do not advance the graph" do
    {:ok, snapshot} = Config.load(@default)
    state = %Domain.PhaseState{phase: "investigate"}

    assert {:ok, failed, [_effect]} =
             Stokowski.PhaseMachine.reduce(snapshot, state, Domain.failed(:timeout))

    assert failed.phase == "investigate"
    assert failed.status == :failed

    assert {:error, {:invalid_event, :approve, :agent}} =
             Stokowski.PhaseMachine.reduce(snapshot, state, Domain.approve())

    assert {:error, {:unknown_event, "write_code"}} =
             Stokowski.PhaseMachine.reduce(snapshot, state, %{"type" => "write_code"})
  end
end
