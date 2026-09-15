defmodule Stokowski.Flow do
  @moduledoc """
  Generic deterministic Fantasia interpreter.

  The input is captured before interpretation. The flow then asks the pure
  phase reducer for effects and sends every effect through one fixed fake
  activity boundary. Production adapters are deliberately not referenced.
  """

  use Continuum.Workflow, version: 1, signals: [phase_event: {Stokowski.Domain, :valid_event?}]

  alias Stokowski.Domain
  alias Stokowski.Domain.WorkflowSnapshot

  def run(input) do
    snapshot = snapshot_from(Map.get(input, :snapshot, Map.get(input, "snapshot", input)))

    journaled =
      Continuum.side_effect(fn ->
        %{
          snapshot: snapshot,
          issue: input_issue(input),
          events: input_events(input),
          await_signal: await_signal?(input)
        }
      end)

    snapshot =
      snapshot_from(Map.get(journaled, :snapshot, Map.get(journaled, "snapshot", journaled)))

    state = Stokowski.PhaseMachine.initial(snapshot)
    issue = Map.get(journaled, :issue, Map.get(journaled, "issue", :unavailable))
    events = Map.get(journaled, :events, Map.get(journaled, "events", []))
    await_signal? = Map.get(journaled, :await_signal, Map.get(journaled, "await_signal", false))
    consume(snapshot, state, events, await_signal?, issue)
  end

  defp consume(
         snapshot,
         %Domain.PhaseState{status: status} = state,
         _events,
         _await_signal?,
         _issue
       )
       when status in [:completed, :cancelled, :failed, :escalated],
       do: result(snapshot, state)

  defp consume(snapshot, state, [], true, issue) when state.status == :waiting do
    event = await(signal(:phase_event))
    consume(snapshot, state, [event], true, issue)
  end

  defp consume(snapshot, state, [], _await_signal?, _issue), do: result(snapshot, state)

  defp consume(snapshot, state, [event | rest], await_signal?, issue) do
    case Stokowski.PhaseMachine.reduce(snapshot, state, event,
           project: project(snapshot),
           issue: issue
         ) do
      {:ok, next_state, effects} ->
        Enum.each(effects, fn effect ->
          _ = activity(Stokowski.Flow.Activities.dispatch(effect))
        end)

        consume(snapshot, next_state, rest, await_signal?, issue)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp result(snapshot, state),
    do: {:ok, %{fingerprint: snapshot.fingerprint, state: state, history: state.transitions}}

  defp input_events(input), do: Map.get(input, :events, Map.get(input, "events", []))

  defp input_issue(input), do: Map.get(input, :issue, Map.get(input, "issue", :unavailable))

  defp await_signal?(input),
    do: Map.get(input, :await_signal, Map.get(input, "await_signal", false))

  defp snapshot_from(%WorkflowSnapshot{} = snapshot), do: snapshot

  defp snapshot_from(snapshot) when is_map(snapshot) do
    %WorkflowSnapshot{
      workflow: Map.get(snapshot, :workflow, Map.get(snapshot, "workflow", "default")),
      entry_phase: Map.get(snapshot, :entry_phase, Map.get(snapshot, "entry_phase", "")),
      graph: Map.get(snapshot, :graph, Map.get(snapshot, "graph", %{})),
      prompts: Map.get(snapshot, :prompts, Map.get(snapshot, "prompts", %{})),
      routing: Map.get(snapshot, :routing, Map.get(snapshot, "routing", %{})),
      schema_version: Map.get(snapshot, :schema_version, Map.get(snapshot, "schema_version", 1)),
      config_version: Map.get(snapshot, :config_version, Map.get(snapshot, "config_version", 1)),
      fingerprint: Map.get(snapshot, :fingerprint, Map.get(snapshot, "fingerprint", "")),
      project: Map.get(snapshot, :project, Map.get(snapshot, "project", :unavailable)),
      capabilities: Map.get(snapshot, :capabilities, Map.get(snapshot, "capabilities", %{}))
    }
  end

  defp project(%WorkflowSnapshot{project: %Domain.Project{name: name}}), do: name
  defp project(_), do: :unavailable
end

defmodule Stokowski.Flow.Activities do
  @moduledoc "Fixed fake activity boundary for the Phase 1 flow."

  use Continuum.Activity

  @doc "Return normalized effect data without touching a provider."
  def dispatch(effect), do: {:ok, %{effect_id: effect.id, kind: effect.kind}}

  @impl true
  def run(effect), do: dispatch(effect)
end
