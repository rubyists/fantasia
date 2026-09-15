defmodule Stokowski.PhaseMachine do
  @moduledoc "Pure phase reduction for an immutable workflow snapshot."

  use Continuum.Pure

  alias Stokowski.Domain

  @type result :: {:ok, Domain.PhaseState.t(), [Domain.RequiredEffect.t()]} | {:error, term()}

  @doc "Creates the initial state. Run and attempt numbers are one-based."
  @spec initial(Domain.WorkflowSnapshot.t()) :: Domain.PhaseState.t()
  def initial(%Domain.WorkflowSnapshot{entry_phase: phase}), do: %Domain.PhaseState{phase: phase}
  def initial(%{entry_phase: phase}), do: %Domain.PhaseState{phase: phase}
  def initial(phase) when is_binary(phase), do: %Domain.PhaseState{phase: phase}

  @doc "Reduces one typed event and returns the next state plus ordered effects."
  @spec reduce(Domain.WorkflowSnapshot.t(), Domain.PhaseState.t(), term()) :: result()
  def reduce(snapshot, state, raw_event) do
    with {:ok, event} <- Domain.normalize_event(raw_event),
         {:ok, phase} <- phase(snapshot, state.phase),
         :ok <- active(state),
         {:ok, next, specs} <- reduce_event(snapshot, phase, state, event) do
      {:ok, next, effects(snapshot, state, specs)}
    end
  end

  @doc false
  def apply(snapshot, state, event), do: reduce(snapshot, state, event)

  @doc "Adds stable caller identity to an effect without changing the graph."
  def reduce(snapshot, state, event, opts) when is_list(opts) do
    snapshot =
      snapshot
      |> put_routing_issue(Keyword.get(opts, :issue))
      |> put_project(Keyword.get(opts, :project))

    reduce(snapshot, state, event)
  end

  @doc "Returns the stable dispatch effect for the current agent phase."
  def dispatch_effect(snapshot, %Domain.PhaseState{} = state) do
    effects(snapshot, state, [
      {:dispatch, %{phase: state.phase, run: state.run, attempt: state.attempt}}
    ])
    |> List.first()
  end

  defp reduce_event(_snapshot, %Domain.Phase{type: :terminal}, state, %Domain.TerminalCompleted{
         reason: reason
       }) do
    {:ok, %{state | status: :completed, feedback: reason}, []}
  end

  defp reduce_event(_snapshot, _phase, state, %Domain.TerminalCompleted{reason: reason}) do
    {:ok, %{state | status: :cancelled, feedback: reason}, [{:cancel, %{reason: reason}}]}
  end

  defp reduce_event(_snapshot, _phase, state, %Domain.RunnerFailed{failure: failure}) do
    {:ok, %{state | status: :failed, failure: failure}, [{:report_failure, %{failure: failure}}]}
  end

  defp reduce_event(snapshot, phase, state, %Domain.AgentCompleted{}) do
    if phase.type == :agent,
      do: transition(snapshot, phase, state, :complete),
      else: {:error, {:invalid_event, :complete, phase.type}}
  end

  defp reduce_event(snapshot, phase, state, %Domain.GateDecision{decision: :approve}) do
    if phase.type == :gate,
      do: transition(snapshot, phase, state, :approve),
      else: {:error, {:invalid_event, :approve, phase.type}}
  end

  defp reduce_event(snapshot, phase, state, %Domain.GateDecision{
         decision: :rework,
         feedback: feedback
       }) do
    if phase.type == :gate,
      do: rework(snapshot, phase, state, feedback),
      else: {:error, {:invalid_event, :rework, phase.type}}
  end

  defp reduce_event(_snapshot, %Domain.Phase{type: :gate}, state, %Domain.GateDecision{
         decision: :escalate,
         feedback: reason
       }) do
    {:ok, %{state | status: :escalated, feedback: reason}, [{:escalate, %{reason: reason}}]}
  end

  defp reduce_event(_snapshot, phase, _state, %Domain.GateDecision{decision: decision}),
    do: {:error, {:invalid_event, decision, phase.type}}

  defp reduce_event(_snapshot, _phase, _state, event), do: {:error, {:invalid_event, event}}

  defp transition(snapshot, phase, state, trigger) do
    case Map.get(phase.transitions, to_string(trigger)) do
      nil ->
        {:error, {:missing_transition, phase.name, trigger}}

      target ->
        with {:ok, target_phase} <- phase(snapshot, target) do
          next_status = status_for(target_phase)

          next = %{
            state
            | phase: target,
              attempt: 1,
              status: next_status,
              transitions: state.transitions ++ [%{from: phase.name, event: trigger, to: target}]
          }

          specs =
            if target_phase.type == :terminal,
              do: [{:complete, %{phase: target}}],
              else: [{:dispatch, %{phase: target, run: next.run, attempt: next.attempt}}]

          {:ok, next, specs}
        end
    end
  end

  defp rework(_snapshot, phase, state, feedback)
       when is_integer(phase.max_rework) and phase.max_rework > 0 and
              state.run >= phase.max_rework do
    failure = %Domain.Failure{
      class: :configuration,
      reason: :max_rework_exceeded,
      retryable: false,
      detail: %{phase: phase.name, run: state.run, feedback: feedback}
    }

    {:ok, %{state | status: :escalated, failure: failure, feedback: feedback},
     [{:escalate, %{failure: failure}}]}
  end

  defp rework(snapshot, phase, state, feedback) do
    case phase.rework_to do
      :unavailable ->
        {:error, {:missing_rework_target, phase.name}}

      target ->
        with {:ok, _target_phase} <- phase(snapshot, target) do
          next = %{
            state
            | phase: target,
              run: state.run + 1,
              attempt: 1,
              status: target_status(snapshot, target),
              feedback: feedback,
              transitions: state.transitions ++ [%{from: phase.name, event: :rework, to: target}]
          }

          {:ok, next,
           [
             {:rework, %{from: phase.name, to: target, feedback: feedback}},
             {:dispatch, %{phase: target, run: next.run, attempt: next.attempt}}
           ]}
        end
    end
  end

  defp effects(snapshot, state, specs) do
    Enum.with_index(specs, fn {kind, data}, index ->
      effect_phase = data[:phase] || data[:to] || state.phase
      effect_run = data[:run] || state.run
      effect_attempt = data[:attempt] || state.attempt

      attempt = %Domain.Attempt{
        project: project_id(snapshot),
        issue: issue_id(snapshot),
        workflow_fingerprint: snapshot.fingerprint,
        phase: effect_phase,
        run: effect_run,
        attempt: effect_attempt
      }

      id =
        {attempt, index, kind, data}
        |> :erlang.term_to_binary([:deterministic])
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)

      %Domain.RequiredEffect{
        id: "effect:#{id}",
        kind: kind,
        attempt: attempt,
        from: state.phase,
        to: data[:phase] || data[:to] || :unavailable,
        data: data
      }
    end)
  end

  defp phase(%Domain.WorkflowSnapshot{graph: graph}, name), do: lookup_phase(graph, name)
  defp phase(%{graph: graph}, name), do: lookup_phase(graph, name)

  defp lookup_phase(graph, name) do
    case Map.get(graph, name) do
      nil -> {:error, {:unknown_phase, name}}
      %Domain.Phase{} = phase -> {:ok, phase}
      raw -> {:ok, struct!(Domain.Phase, raw)}
    end
  end

  defp active(%Domain.PhaseState{status: :running}), do: :ok
  defp active(%Domain.PhaseState{status: :waiting}), do: :ok
  defp active(%{status: :running}), do: :ok
  defp active(%{status: :waiting}), do: :ok
  defp active(%Domain.PhaseState{status: status}), do: {:error, {:terminal_state, status}}
  defp active(%{status: status}), do: {:error, {:terminal_state, status}}

  defp project_id(%Domain.WorkflowSnapshot{project: %Domain.Project{id: id}}), do: id
  defp project_id(%{project: project}) when is_binary(project), do: project
  defp project_id(_), do: :unavailable

  defp put_project(snapshot, nil), do: snapshot

  defp put_project(%Domain.WorkflowSnapshot{} = snapshot, %Domain.Project{} = project),
    do: %{snapshot | project: project}

  defp put_project(%Domain.WorkflowSnapshot{} = snapshot, project) when is_binary(project),
    do: %{snapshot | project: %Domain.Project{id: project, name: project}}

  defp put_project(snapshot, _), do: snapshot

  defp put_routing_issue(snapshot, nil), do: snapshot

  defp put_routing_issue(%Domain.WorkflowSnapshot{} = snapshot, issue),
    do: %{snapshot | routing: Map.put(snapshot.routing, :issue, issue)}

  defp put_routing_issue(snapshot, _), do: snapshot

  defp issue_id(%Domain.WorkflowSnapshot{routing: routing}),
    do: issue_identity(Map.get(routing, :issue, :unavailable))

  defp issue_id(%{routing: routing}),
    do: issue_identity(Map.get(routing, :issue, Map.get(routing, "issue", :unavailable)))

  defp issue_identity(%Domain.Issue{id: id}), do: id
  defp issue_identity(%{"id" => id}), do: id
  defp issue_identity(%{id: id}), do: id
  defp issue_identity(issue), do: issue

  defp status_for(%Domain.Phase{type: :gate}), do: :waiting
  defp status_for(%Domain.Phase{type: :terminal}), do: :completed
  defp status_for(%Domain.Phase{}), do: :running

  defp target_status(snapshot, target) do
    case phase(snapshot, target) do
      {:ok, target_phase} -> status_for(target_phase)
      _ -> :running
    end
  end
end
