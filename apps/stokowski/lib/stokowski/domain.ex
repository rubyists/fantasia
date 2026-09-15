defmodule Stokowski.Domain do
  @moduledoc """
  Provider-neutral values used by Fantasia's deterministic core.

  Optional provider fields use `:unavailable` (or `{:unavailable, reason}`)
  instead of an invented empty value. This keeps a missing tracker capability
  distinguishable from a provider that returned an empty value.
  """

  @type unavailable :: :unavailable | {:unavailable, atom() | binary()}

  use Continuum.Pure

  def unavailable(reason \\ :not_provided), do: {:unavailable, reason}

  defmodule Issue do
    @moduledoc "A normalized issue received from a tracker."
    @enforce_keys [:id, :identifier, :title]
    defstruct id: nil,
              identifier: nil,
              title: nil,
              description: :unavailable,
              url: :unavailable,
              priority: :unavailable,
              state: :unavailable,
              branch: :unavailable,
              project: :unavailable,
              labels: [],
              comments: []

    @type t :: %__MODULE__{
            id: binary(),
            identifier: binary(),
            title: binary(),
            description: Stokowski.Domain.unavailable() | binary(),
            url: Stokowski.Domain.unavailable() | binary(),
            priority: Stokowski.Domain.unavailable() | term(),
            state: Stokowski.Domain.unavailable() | binary(),
            branch: Stokowski.Domain.unavailable() | binary(),
            project: Stokowski.Domain.unavailable() | term(),
            labels: [binary()],
            comments: [Stokowski.Domain.Comment.t()]
          }
  end

  defmodule Comment do
    @moduledoc "A normalized issue comment with explicit attribution."
    @enforce_keys [:body]
    defstruct id: :unavailable,
              body: "",
              created_at: :unavailable,
              author: :unavailable

    @type t :: %__MODULE__{
            id: Stokowski.Domain.unavailable() | binary(),
            body: binary(),
            created_at: Stokowski.Domain.unavailable() | DateTime.t(),
            author: Stokowski.Domain.unavailable() | binary()
          }
  end

  defmodule Project do
    @moduledoc "The stable project identity used by an attempt."
    @enforce_keys [:id, :name]
    defstruct id: nil, name: nil
    @type t :: %__MODULE__{id: binary(), name: binary()}
  end

  defmodule Phase do
    @moduledoc "One node in a normalized workflow graph."
    @enforce_keys [:name, :type]
    defstruct name: nil,
              type: :agent,
              prompt: :unavailable,
              linear_state: :unavailable,
              runner: :unavailable,
              model: :unavailable,
              effort: :unavailable,
              session: :inherit,
              transitions: %{},
              rework_to: :unavailable,
              max_rework: :unavailable

    @type t :: %__MODULE__{
            name: binary(),
            type: :agent | :gate | :terminal,
            prompt: Stokowski.Domain.unavailable() | binary(),
            linear_state: Stokowski.Domain.unavailable() | binary(),
            runner: Stokowski.Domain.unavailable() | binary(),
            model: Stokowski.Domain.unavailable() | binary(),
            effort: Stokowski.Domain.unavailable() | binary(),
            session: :inherit | :handoff | :fresh,
            transitions: %{optional(binary()) => binary()},
            rework_to: Stokowski.Domain.unavailable() | binary(),
            max_rework: Stokowski.Domain.unavailable() | non_neg_integer()
          }
  end

  defmodule WorkflowSnapshot do
    @moduledoc "Immutable, checkout-independent workflow input to the reducer."
    @enforce_keys [
      :workflow,
      :entry_phase,
      :graph,
      :prompts,
      :routing,
      :schema_version,
      :config_version,
      :fingerprint
    ]
    defstruct workflow: nil,
              entry_phase: nil,
              graph: %{},
              prompts: %{},
              routing: %{},
              schema_version: 1,
              config_version: 1,
              fingerprint: nil,
              project: :unavailable,
              capabilities: %{}

    @type t :: %__MODULE__{
            workflow: binary(),
            entry_phase: binary(),
            graph: %{optional(binary()) => Stokowski.Domain.Phase.t()},
            prompts: %{optional(binary()) => term()},
            routing: map(),
            schema_version: pos_integer(),
            config_version: pos_integer(),
            fingerprint: binary(),
            project: Stokowski.Domain.unavailable() | Stokowski.Domain.Project.t(),
            capabilities: map()
          }
  end

  defmodule Attempt do
    @moduledoc "Stable identity for one dispatch attempt."
    @enforce_keys [:project, :issue, :workflow_fingerprint, :phase, :run, :attempt]
    defstruct project: nil,
              issue: nil,
              workflow_fingerprint: nil,
              phase: nil,
              run: 1,
              attempt: 1

    @type t :: %__MODULE__{
            project: binary(),
            issue: binary(),
            workflow_fingerprint: binary(),
            phase: binary(),
            run: pos_integer(),
            attempt: pos_integer()
          }
  end

  defmodule PhaseState do
    @moduledoc "Current reducer state; it contains no provider process state."
    @enforce_keys [:phase]
    defstruct phase: nil,
              run: 1,
              attempt: 1,
              status: :running,
              transitions: [],
              feedback: :unavailable,
              failure: :unavailable,
              rework_counts: %{}

    @type t :: %__MODULE__{
            phase: binary(),
            run: pos_integer(),
            attempt: pos_integer(),
            status: :running | :waiting | :completed | :failed | :cancelled | :escalated,
            transitions: [map()],
            feedback: Stokowski.Domain.unavailable() | binary(),
            failure: Stokowski.Domain.unavailable() | term(),
            rework_counts: %{optional(binary()) => non_neg_integer()}
          }
  end

  defmodule AgentCompleted do
    @moduledoc "Typed successful completion signal from an agent runner."
    defstruct report: :unavailable, result: :unavailable
    @type t :: %__MODULE__{report: term(), result: term()}
  end

  defmodule GateDecision do
    @moduledoc "Typed decision from a human or external gate."
    @enforce_keys [:decision]
    defstruct decision: nil, feedback: :unavailable, actor: :unavailable

    @type t :: %__MODULE__{
            decision: :approve | :rework | :escalate,
            feedback: term(),
            actor: term()
          }
  end

  defmodule RunnerFailed do
    @moduledoc "Typed runner failure; failures never select a graph edge."
    @enforce_keys [:failure]
    defstruct failure: nil
    @type t :: %__MODULE__{failure: Stokowski.Domain.Failure.t() | term()}
  end

  defmodule TerminalCompleted do
    @moduledoc "Typed external terminal signal."
    defstruct reason: :external
    @type t :: %__MODULE__{reason: term()}
  end

  defmodule Failure do
    @moduledoc "Classified, provider-neutral failure."
    @enforce_keys [:class, :reason]
    defstruct class: nil, reason: nil, retryable: false, detail: :unavailable

    @type t :: %__MODULE__{
            class: :runner | :configuration | :provider | :timeout | :cancelled | atom(),
            reason: term(),
            retryable: boolean(),
            detail: term()
          }
  end

  defmodule RunnerResult do
    @moduledoc "Normalized result crossing the runner boundary."
    defstruct status: :complete, output: :unavailable, report: :unavailable, usage: :unavailable
    @type t :: %__MODULE__{status: atom(), output: term(), report: term(), usage: term()}
  end

  defmodule ReportResult do
    @moduledoc "Structured report data after safe decoding."
    defstruct verdict: :unavailable,
              headline: :unavailable,
              summary: :unavailable,
              classification: :unavailable,
              confidence: :unavailable,
              key_points: [],
              claims: [],
              data_sources: [],
              verification: [],
              changes: [],
              artifacts: [],
              risks: [],
              assumptions: [],
              open_questions: [],
              next: :unavailable,
              next_steps: []

    @type t :: %__MODULE__{
            verdict: term(),
            headline: term(),
            summary: term(),
            classification: term(),
            confidence: term(),
            key_points: list(),
            claims: list(),
            data_sources: list(),
            verification: list(),
            changes: list(),
            artifacts: list(),
            risks: list(),
            assumptions: list(),
            open_questions: list(),
            next: term(),
            next_steps: list()
          }
  end

  defmodule RequiredEffect do
    @moduledoc "An ordered effect emitted by the pure reducer."
    @enforce_keys [:id, :kind, :attempt]
    defstruct id: nil,
              kind: nil,
              attempt: nil,
              from: :unavailable,
              to: :unavailable,
              data: %{}

    @type t :: %__MODULE__{
            id: binary(),
            kind: atom(),
            attempt: Stokowski.Domain.Attempt.t(),
            from: term(),
            to: term(),
            data: map()
          }
  end

  def agent_completed(result \\ :unavailable, report \\ :unavailable),
    do: %AgentCompleted{result: result, report: report}

  def approve(feedback \\ :unavailable, actor \\ :unavailable),
    do: %GateDecision{decision: :approve, feedback: feedback, actor: actor}

  def rework(feedback \\ :unavailable, actor \\ :unavailable),
    do: %GateDecision{decision: :rework, feedback: feedback, actor: actor}

  def escalate(reason \\ :manual, actor \\ :unavailable),
    do: %GateDecision{decision: :escalate, feedback: reason, actor: actor}

  def failed(%Failure{} = failure), do: %RunnerFailed{failure: failure}

  def failed(reason),
    do: %RunnerFailed{failure: %Failure{class: failure_class(reason), reason: reason}}

  def terminal(reason \\ :external), do: %TerminalCompleted{reason: reason}

  def normalize_event(%AgentCompleted{} = event), do: {:ok, event}
  def normalize_event(%GateDecision{} = event), do: {:ok, event}
  def normalize_event(%RunnerFailed{} = event), do: {:ok, event}
  def normalize_event(%TerminalCompleted{} = event), do: {:ok, event}

  def normalize_event(:complete), do: {:ok, agent_completed()}
  def normalize_event(:approve), do: {:ok, approve()}
  def normalize_event(:rework), do: {:ok, rework()}
  def normalize_event(:escalate), do: {:ok, escalate()}
  def normalize_event(:terminal), do: {:ok, terminal()}

  def normalize_event(%{"type" => type} = event) do
    case to_string(type) do
      "complete" -> {:ok, agent_completed(Map.get(event, "result"), Map.get(event, "report"))}
      "approve" -> {:ok, approve(Map.get(event, "feedback"), Map.get(event, "actor"))}
      "rework" -> {:ok, rework(Map.get(event, "feedback"), Map.get(event, "actor"))}
      "escalate" -> {:ok, escalate(Map.get(event, "reason"), Map.get(event, "actor"))}
      "failure" -> {:ok, failed(Map.get(event, "failure", Map.get(event, "reason")))}
      "terminal" -> {:ok, terminal(Map.get(event, "reason", :external))}
      other -> {:error, {:unknown_event, other}}
    end
  end

  def normalize_event(%{type: _type} = event),
    do:
      event
      |> Map.new(fn {key, value} -> {to_string(key), value} end)
      |> normalize_event()

  def normalize_event(other), do: {:error, {:invalid_event, other}}

  @doc "Signal-contract validator for the typed phase event boundary."
  def valid_event?(event), do: match?({:ok, _normalized}, normalize_event(event))

  defp failure_class(:timeout), do: :timeout
  defp failure_class(:cancelled), do: :cancelled
  defp failure_class(_reason), do: :runner
end
