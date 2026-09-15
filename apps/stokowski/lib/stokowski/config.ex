defmodule Stokowski.Config do
  @moduledoc """
  The deterministic configuration boundary.

  `Stokowski.Workflow` remains responsible for lossless YAML parsing. This
  module turns that representation into a validated immutable snapshot. The
  snapshot contains resolved prompt bodies and only provider-neutral execution
  data, so it is safe to journal and its fingerprint does not depend on a
  checkout path, environment variable, timestamp, or secret.
  """

  alias Stokowski.Domain.{Phase, Project, WorkflowSnapshot}

  @schema_version 1
  @config_version 1
  @secret_keys ~w(api_key token secret password access_token authorization)a

  defmodule Loader do
    @moduledoc "Lossless canonical YAML and legacy WORKFLOW.md loader."

    @spec read(Path.t()) :: {:ok, map(), binary()} | {:error, term()}
    def read(path) do
      path = Path.expand(path)

      with {:ok, content} <- File.read(path) do
        if Path.extname(path) in [".yaml", ".yml"] do
          with {:ok, workflow} <- Stokowski.Workflow.read(path),
               {:ok, raw} <- Stokowski.Workflow.normalize(workflow) do
            {:ok, Map.put(raw, "__phase_order__", declaration_order(workflow)), ""}
          end
        else
          parse_markdown(content)
        end
      end
    end

    @spec parse(binary()) :: {:ok, map(), binary()} | {:error, term()}
    def parse(content) when is_binary(content) do
      if String.starts_with?(content, "---") do
        parse_markdown(content)
      else
        with {:ok, workflow} <- Stokowski.Workflow.parse(content),
             {:ok, raw} <- Stokowski.Workflow.normalize(workflow) do
          {:ok, raw, ""}
        end
      end
    end

    defp parse_markdown(content) do
      case Regex.run(~r/\A---\s*\n(.*?)\n---\s*(.*)\z/s, content, capture: :all_but_first) do
        [front_matter, body] ->
          with {:ok, workflow} <- Stokowski.Workflow.parse(front_matter),
               {:ok, raw} <- Stokowski.Workflow.normalize(workflow) do
            {:ok, Map.put(raw, "__phase_order__", declaration_order(workflow)), String.trim(body)}
          end

        _ ->
          {:error,
           {:legacy_migration_required,
            "WORKFLOW.md needs YAML front matter with a deterministic states graph"}}
      end
    end

    defp declaration_order(%Stokowski.Workflow{documents: [{:mapping, entries}]}) do
      case find_mapping(entries, "states") do
        {:mapping, state_entries} ->
          Enum.map(state_entries, fn {name, _value} -> to_string(name) end)

        _ ->
          []
      end
    end

    defp declaration_order(_), do: []

    defp find_mapping([{key, value} | _rest], wanted) when key == wanted, do: value
    defp find_mapping([_ | rest], wanted), do: find_mapping(rest, wanted)
    defp find_mapping([], _wanted), do: nil
  end

  @doc "Load a YAML or legacy `WORKFLOW.md` and build its selected snapshot."
  @spec load(Path.t(), keyword()) :: {:ok, WorkflowSnapshot.t()} | {:error, term()}
  def load(path, opts \\ []) do
    with {:ok, raw, legacy_body} <- Loader.read(path),
         {:ok, snapshot} <-
           snapshot(raw, Keyword.put(opts, :workflow_dir, Path.dirname(path)), legacy_body),
         :ok <- validate(snapshot) do
      {:ok, snapshot}
    end
  end

  @doc "Parse configuration text without requiring a checkout."
  @spec from_yaml(binary(), keyword()) :: {:ok, WorkflowSnapshot.t()} | {:error, term()}
  def from_yaml(content, opts \\ []) do
    with {:ok, raw, legacy_body} <- Loader.parse(content),
         {:ok, snapshot} <- snapshot(raw, opts, legacy_body),
         :ok <- validate(snapshot) do
      {:ok, snapshot}
    end
  end

  @doc "Build a snapshot from an already normalized string-keyed map."
  @spec snapshot(map(), keyword(), binary()) :: {:ok, WorkflowSnapshot.t()} | {:error, term()}
  def snapshot(raw, opts \\ [], legacy_body \\ "") when is_map(raw) do
    workflow_dir = Keyword.get(opts, :workflow_dir, ".")
    project_name = Keyword.get(opts, :project)
    labels = Keyword.get(opts, :labels, [])
    prompt_contents = Keyword.get(opts, :prompt_contents, %{})

    with :ok <- legacy_source_valid(raw, legacy_body),
         {:ok, project_raw, project_identity} <- select_project(raw, project_name),
         {:ok, workflows} <- workflows(raw, project_raw, workflow_dir),
         :ok <- legacy_graph_required(workflows, legacy_body),
         {:ok, workflow_name, workflow_raw, routing} <-
           select_workflow(raw, project_raw, workflows, labels, opts),
         {:ok, graph, declared_entry} <- build_graph(workflow_raw),
         {:ok, entry_phase} <-
           entry_phase(graph, map_get(workflow_raw, "entry_phase", declared_entry)),
         {:ok, prompts} <-
           resolve_prompts(
             raw,
             project_raw,
             workflow_raw,
             graph,
             workflow_dir,
             prompt_contents,
             legacy_body,
             Keyword.get(opts, :allow_absolute_paths, false)
           ),
         graph <- resolved_graph(graph, prompts),
         {:ok, snapshot_data} <-
           build_snapshot_data(
             raw,
             project_identity,
             workflow_name,
             entry_phase,
             graph,
             prompts,
             routing
           ) do
      fingerprint = fingerprint(snapshot_data)

      {:ok,
       %WorkflowSnapshot{
         workflow: workflow_name,
         entry_phase: entry_phase,
         graph: graph,
         prompts: prompts,
         routing: routing,
         schema_version: snapshot_data.schema_version,
         config_version: snapshot_data.config_version,
         fingerprint: fingerprint,
         project: project_identity,
         capabilities: Map.get(snapshot_data, :capabilities, %{})
       }}
    end
  end

  @doc "Validate a snapshot's graph and immutable data."
  @spec validate(WorkflowSnapshot.t()) :: :ok | {:error, [term()]}
  def validate(%WorkflowSnapshot{} = snapshot) do
    errors =
      snapshot.graph
      |> Enum.flat_map(fn {name, phase} -> validate_phase(name, phase, snapshot.graph) end)
      |> then(&(&1 ++ validate_entry(snapshot)))
      |> then(&(&1 ++ validate_reachability(snapshot)))

    if errors == [], do: :ok, else: {:error, errors}
  end

  @doc "Return the checkout-independent fingerprint for snapshot content."
  @spec fingerprint(map() | WorkflowSnapshot.t()) :: binary()
  def fingerprint(%WorkflowSnapshot{} = snapshot), do: snapshot_data(snapshot) |> fingerprint()

  def fingerprint(data) when is_map(data) do
    data
    |> canonicalize()
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc "Resolve the first matching routing rule for normalized issue labels."
  @spec route(map(), [binary()]) :: {:ok, binary(), map()} | {:error, term()}
  def route(raw, labels \\ []) when is_map(raw) do
    routing =
      if Map.has_key?(raw, "routing") or Map.has_key?(raw, :routing),
        do: map_get(raw, "routing", %{}),
        else: raw

    rules = map_get(routing, "rules", [])

    normalized =
      labels
      |> List.wrap()
      |> MapSet.new(&normalize_label/1)

    case Enum.find(rules, fn rule ->
           is_map(rule) and
             MapSet.member?(normalized, normalize_label(map_get(rule, "label", "")))
         end) do
      nil ->
        case map_get(routing, "default") do
          name when is_binary(name) and name != "" ->
            {:ok, name, %{default: true, label: :unavailable}}

          name when is_atom(name) and not is_nil(name) ->
            {:ok, Atom.to_string(name), %{default: true, label: :unavailable}}

          _ ->
            {:error, :no_workflow_route}
        end

      rule ->
        {:ok, to_string(map_get(rule, "workflow")),
         %{default: false, label: normalize_label(map_get(rule, "label"))}}
    end
  end

  defp select_project(raw, requested) do
    case map_get(raw, "projects") do
      projects when is_list(projects) and projects != [] ->
        selected =
          Enum.find(projects, fn project ->
            to_string(map_get(project, "name", "")) == to_string(requested)
          end) ||
            if(is_nil(requested), do: List.first(projects))

        if is_map(selected) do
          name = String.trim(to_string(map_get(selected, "name", "")))

          if name == "" do
            {:error, :project_name_required}
          else
            id = map_get(selected, "id", name)
            {:ok, selected, %Project{id: to_string(id), name: name}}
          end
        else
          {:error, {:unknown_project, requested}}
        end

      _ ->
        project = map_get(raw, "project", %{})
        name = to_string(map_get(project, "name", map_get(raw, "project_name", "default")))
        {:ok, raw, %Project{id: name, name: name}}
    end
  end

  defp workflows(raw, project, workflow_dir) do
    external = load_external_workflows(workflow_dir)
    inline = map_get(project, "workflows", map_get(raw, "workflows", %{}))
    states = map_get(project, "states", map_get(raw, "states", %{}))

    workflows =
      external
      |> Map.merge(if(is_map(inline), do: inline, else: %{}))
      |> maybe_put_default(states, project, raw)

    {:ok, workflows}
  end

  defp legacy_graph_required(%{} = workflows, "") when map_size(workflows) > 0, do: :ok
  defp legacy_graph_required(%{}, ""), do: {:error, :no_workflows}
  defp legacy_graph_required(workflows, _body) when map_size(workflows) > 0, do: :ok

  defp legacy_graph_required(_workflows, _body),
    do:
      {:error,
       {:legacy_migration_required,
        "legacy WORKFLOW.md has no deterministic phase graph; add states/transitions to canonical YAML"}}

  @doc "Return the actionable diagnostic used when migrating prose-only legacy workflows."
  def migration_diagnostic,
    do:
      {:legacy_migration_required,
       "legacy WORKFLOW.md has no deterministic phase graph; add states/transitions to canonical YAML"}

  defp legacy_source_valid(_raw, ""), do: :ok

  defp legacy_source_valid(raw, _body) do
    if has_declared_graph?(raw),
      do: :ok,
      else:
        {:error,
         {:legacy_migration_required,
          "legacy WORKFLOW.md has no deterministic phase graph; add states/transitions to canonical YAML"}}
  end

  defp has_declared_graph?(raw) do
    direct = map_get(raw, "states", %{})
    inline = map_get(raw, "workflows", %{})
    projects = map_get(raw, "projects", [])

    (is_map(direct) and map_size(direct) > 0) or
      (is_map(inline) and map_size(inline) > 0) or
      (is_list(projects) and
         Enum.any?(projects, fn project ->
           is_map(project) and map_size(map_get(project, "states", %{})) > 0
         end))
  end

  defp load_external_workflows(workflow_dir) do
    Path.join(workflow_dir, "workflows")
    |> Path.expand()
    |> case do
      directory ->
        if File.dir?(directory) do
          directory
          |> Path.join("*.y*ml")
          |> Path.wildcard()
          |> Enum.sort()
          |> Enum.reduce(%{}, fn path, acc ->
            with {:ok, normalized, _body} <- Loader.read(path) do
              name = Path.basename(path) |> String.split(".") |> List.first()
              Map.put(acc, name, normalized)
            else
              _ -> acc
            end
          end)
        else
          %{}
        end
    end
  end

  defp maybe_put_default(workflows, states, project, raw)
       when is_map(states) and map_size(states) > 0 do
    workflow = %{
      "states" => states,
      "prompts" => map_get(project, "prompts", map_get(raw, "prompts", %{}))
    }

    Map.put_new(workflows, "default", workflow)
  end

  defp maybe_put_default(workflows, _states, _project, _raw), do: workflows

  defp select_workflow(raw, project, workflows, labels, opts) do
    requested = Keyword.get(opts, :workflow)

    with {:ok, routed, decision} <-
           if(requested,
             do: {:ok, to_string(requested), %{default: false, label: :explicit}},
             else: route(map_get(project, "routing", map_get(raw, "routing", %{})), labels)
           ),
         workflow_raw when is_map(workflow_raw) <- Map.get(workflows, routed) do
      {:ok, routed, workflow_raw, Map.put(decision, :workflow, routed)}
    else
      nil ->
        {:error, {:unknown_workflow, requested}}

      {:error, _} = error ->
        if map_size(workflows) == 1 do
          [{name, workflow_raw}] = Map.to_list(workflows)
          {:ok, name, workflow_raw, %{default: true, label: :unavailable, workflow: name}}
        else
          error
        end
    end
  end

  defp build_graph(workflow_raw) do
    raw_states = map_get(workflow_raw, "states", workflow_raw)
    phase_order = map_get(workflow_raw, "__phase_order__", [])
    ordered_entries = ordered_entries(raw_states, phase_order)

    if not is_map(raw_states) or map_size(raw_states) == 0 do
      {:error, :states_required}
    else
      {graph, first_agent} =
        Enum.reduce(ordered_entries, {%{}, nil}, fn {name, raw}, {acc, first_agent} ->
          name = to_string(name)
          raw = if is_map(raw), do: raw, else: %{}
          type = parse_type(map_get(raw, "type", "agent"))

          phase = %Phase{
            name: name,
            type: type,
            prompt: optional(map_get(raw, "prompt")),
            linear_state: optional(map_get(raw, "linear_state")),
            runner: optional(map_get(raw, "runner")),
            model: optional(map_get(raw, "model")),
            effort: optional(map_get(raw, "effort")),
            session: parse_session(map_get(raw, "session", "inherit")),
            transitions: normalize_transitions(map_get(raw, "transitions", %{})),
            rework_to: optional(map_get(raw, "rework_to")),
            max_rework: positive_or_unavailable(map_get(raw, "max_rework"))
          }

          {Map.put(acc, name, phase),
           if(is_nil(first_agent) and type == :agent, do: name, else: first_agent)}
        end)

      declared_entry = map_get(workflow_raw, "entry_phase", map_get(workflow_raw, "entry_state"))
      entry = declared_entry || inferred_entry(graph, first_agent)
      {:ok, graph, entry}
    end
  end

  defp entry_phase(_graph, name) when is_binary(name) and name != "", do: {:ok, name}
  defp entry_phase(_graph, nil), do: {:error, :agent_entry_phase_required}

  defp inferred_entry(graph, first_agent) do
    targets =
      graph
      |> Enum.flat_map(fn {_name, phase} -> Map.values(phase.transitions) end)
      |> MapSet.new()

    graph
    |> Enum.filter(fn {name, phase} ->
      phase.type == :agent and not MapSet.member?(targets, name)
    end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
    |> List.first() || first_agent
  end

  defp resolve_prompts(
         raw,
         project,
         workflow,
         graph,
         workflow_dir,
         provided,
         legacy_body,
         allow_absolute_paths
       ) do
    prompts =
      map_get(workflow, "prompts", map_get(project, "prompts", map_get(raw, "prompts", %{})))

    globals = map_get(prompts, "global_prompt", map_get(prompts, "global", []))
    globals = if is_list(globals), do: globals, else: [globals]

    with {:ok, global_bodies} <-
           resolve_many(globals, workflow_dir, provided, allow_absolute_paths),
         {:ok, phase_bodies} <-
           resolve_phase_prompts(graph, workflow_dir, provided, allow_absolute_paths),
         {:ok, legacy} <- resolve_legacy(legacy_body, raw, workflow_dir, provided) do
      {:ok, %{global: global_bodies, phases: phase_bodies, legacy: legacy}}
    end
  end

  defp resolve_phase_prompts(graph, workflow_dir, provided, allow_absolute_paths) do
    Enum.reduce_while(graph, {:ok, %{}}, fn {name, phase}, {:ok, acc} ->
      case phase.prompt do
        :unavailable ->
          {:cont, {:ok, acc}}

        path ->
          case resolve_prompt(path, workflow_dir, provided, allow_absolute_paths) do
            {:ok, body} -> {:cont, {:ok, Map.put(acc, name, body)}}
            {:error, _} = error -> {:halt, error}
          end
      end
    end)
  end

  defp resolved_graph(graph, %{phases: phases}) do
    Map.new(graph, fn {name, phase} ->
      case Map.fetch(phases, name) do
        {:ok, body} -> {name, %{phase | prompt: body}}
        :error -> {name, phase}
      end
    end)
  end

  defp resolve_legacy("", _raw, _dir, _provided), do: {:ok, :unavailable}
  defp resolve_legacy(body, _raw, _dir, _provided), do: {:ok, body}

  defp resolve_many(paths, workflow_dir, provided, allow_absolute_paths) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, acc} ->
      case resolve_prompt(path, workflow_dir, provided, allow_absolute_paths) do
        {:ok, body} -> {:cont, {:ok, acc ++ [body]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp resolve_prompt(:unavailable, _dir, _provided, _allow_absolute_paths), do: {:ok, ""}

  defp resolve_prompt(path, workflow_dir, provided, allow_absolute_paths) do
    path = to_string(path)

    case Map.fetch(provided, path) do
      {:ok, body} when is_binary(body) ->
        {:ok, body}

      _ ->
        candidate = Path.expand(path, workflow_dir)
        relative = Path.relative_to(candidate, Path.expand(workflow_dir))
        absolute? = Path.type(path) == :absolute
        outside? = relative == ".." or String.starts_with?(relative, "../")

        cond do
          absolute? and not allow_absolute_paths ->
            {:error, {:prompt_path_outside_workflow, path}}

          outside? and not (absolute? and allow_absolute_paths) ->
            {:error, {:prompt_path_outside_workflow, path}}

          true ->
            case File.read(candidate) do
              {:ok, body} -> {:ok, body}
              {:error, _} -> {:error, {:prompt_not_found, path}}
            end
        end
    end
  end

  defp build_snapshot_data(raw, project, workflow, entry, graph, prompts, routing) do
    schema_version =
      positive_int(map_get(raw, "schema_version", @schema_version), @schema_version)

    config_version =
      positive_int(map_get(raw, "config_version", @config_version), @config_version)

    capabilities =
      raw
      |> map_get("capabilities", %{})
      |> sanitize_capabilities()

    {:ok,
     %{
       schema_version: schema_version,
       config_version: config_version,
       project: project_data(project),
       workflow: workflow,
       entry_phase: entry,
       graph: graph_data(graph),
       prompts: prompts,
       routing: routing,
       capabilities: capabilities
     }}
  end

  defp snapshot_data(%WorkflowSnapshot{} = snapshot) do
    %{
      schema_version: snapshot.schema_version,
      config_version: snapshot.config_version,
      project: project_data(snapshot.project),
      workflow: snapshot.workflow,
      entry_phase: snapshot.entry_phase,
      graph: graph_data(snapshot.graph),
      prompts: snapshot.prompts,
      routing: snapshot.routing,
      capabilities: sanitize_capabilities(snapshot.capabilities)
    }
  end

  defp project_data(%Project{id: id, name: name}), do: %{id: id, name: name}
  defp project_data(other), do: other

  defp graph_data(graph) do
    graph
    |> Enum.map(fn {name, phase} ->
      {name,
       %{
         name: phase.name,
         type: phase.type,
         prompt: phase.prompt,
         linear_state: phase.linear_state,
         runner: phase.runner,
         model: phase.model,
         effort: phase.effort,
         session: phase.session,
         transitions: phase.transitions,
         rework_to: phase.rework_to,
         max_rework: phase.max_rework
       }}
    end)
    |> Map.new()
  end

  defp canonicalize(value) when is_map(value) do
    value
    |> Enum.map(fn {key, val} -> {canonical_key(key), canonicalize(val)} end)
    |> Enum.sort_by(fn {key, _value} -> key end)
  end

  defp canonicalize(value) when is_list(value), do: Enum.map(value, &canonicalize/1)
  defp canonicalize(value), do: value

  defp canonical_key(key) when is_atom(key), do: Atom.to_string(key)
  defp canonical_key(key), do: key

  defp sanitize_capabilities(value) when is_map(value) do
    value
    |> Enum.reject(fn {key, _value} ->
      secret_key?(key)
    end)
    |> Map.new(fn {key, val} -> {key, sanitize_capabilities(val)} end)
  end

  defp sanitize_capabilities(value) when is_list(value),
    do: Enum.map(value, &sanitize_capabilities/1)

  defp sanitize_capabilities(value), do: value

  defp secret_key?(key) do
    key = key |> to_string() |> String.downcase() |> String.replace("-", "_")

    key in Enum.map(@secret_keys, &Atom.to_string/1) or
      String.contains?(key, "secret") or String.ends_with?(key, "_token")
  end

  defp validate_phase(name, %Phase{} = phase, graph) do
    transition_errors =
      phase.transitions
      |> Enum.flat_map(fn {trigger, target} ->
        if Map.has_key?(graph, target),
          do: [],
          else: [{:unknown_transition_target, name, trigger, target}]
      end)

    type_errors =
      if phase.type in [:agent, :gate, :terminal],
        do: [],
        else: [{:invalid_phase_type, name, phase.type}]

    prompt_errors =
      cond do
        phase.type == :agent and phase.prompt == :unavailable ->
          [{:prompt_required, name}]

        phase.type == :agent and is_binary(phase.prompt) and String.trim(phase.prompt) == "" ->
          [{:prompt_required, name}]

        true ->
          []
      end

    trigger_errors =
      case phase.type do
        :agent ->
          if Map.has_key?(phase.transitions, "complete"),
            do: [],
            else: [{:completion_transition_required, name}]

        :gate ->
          if Map.has_key?(phase.transitions, "approve"),
            do: [],
            else: [{:approval_transition_required, name}]

        :terminal ->
          if phase.transitions == %{}, do: [], else: [{:terminal_must_not_transition, name}]

        _ ->
          []
      end

    gate_errors =
      cond do
        phase.type != :gate ->
          []

        phase.rework_to == :unavailable ->
          [{:rework_target_required, name}]

        not Map.has_key?(graph, phase.rework_to) ->
          [{:unknown_rework_target, name, phase.rework_to}]

        true ->
          []
      end

    transition_errors ++ type_errors ++ prompt_errors ++ trigger_errors ++ gate_errors
  end

  defp validate_entry(%WorkflowSnapshot{entry_phase: entry, graph: graph}) do
    cond do
      not Map.has_key?(graph, entry) -> [{:invalid_entry_phase, entry}]
      graph[entry].type != :agent -> [{:entry_phase_must_be_agent, entry}]
      true -> []
    end
  end

  defp validate_reachability(%WorkflowSnapshot{entry_phase: entry, graph: graph}) do
    if Map.has_key?(graph, entry) and not reaches_terminal?(graph, entry, MapSet.new()),
      do: [{:terminal_unreachable, entry}],
      else: []
  end

  defp reaches_terminal?(graph, name, visited) do
    case Map.get(graph, name) do
      nil ->
        false

      phase ->
        cond do
          MapSet.member?(visited, name) ->
            false

          phase.type == :terminal ->
            true

          true ->
            visited = MapSet.put(visited, name)

            phase.transitions
            |> Map.values()
            |> Enum.any?(&reaches_terminal?(graph, &1, visited))
        end
    end
  end

  defp normalize_transitions(value) when is_map(value),
    do: Map.new(value, fn {key, val} -> {to_string(key), to_string(val)} end)

  defp normalize_transitions(_), do: %{}

  defp parse_type(value) do
    case to_string(value) do
      "agent" -> :agent
      "gate" -> :gate
      "terminal" -> :terminal
      _other -> :invalid
    end
  end

  defp parse_session(value) do
    case to_string(value) do
      "fresh" -> :fresh
      "handoff" -> :handoff
      _ -> :inherit
    end
  end

  defp optional(nil), do: :unavailable
  defp optional(""), do: :unavailable
  defp optional(value), do: value

  defp positive_or_unavailable(value) when is_integer(value) and value > 0, do: value

  defp positive_or_unavailable(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> int
      _ -> :unavailable
    end
  end

  defp positive_or_unavailable(_), do: :unavailable

  defp positive_int(value, _default) when is_integer(value) and value > 0, do: value

  defp positive_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> int
      _ -> default
    end
  end

  defp positive_int(_value, default), do: default

  defp map_get(map, key, default \\ nil) when is_map(map) do
    Map.get(map, key, Map.get(map, maybe_atom(key), default))
  end

  defp maybe_atom(key) when is_atom(key), do: key

  defp maybe_atom(key) when is_binary(key) do
    try do
      String.to_existing_atom(key)
    rescue
      ArgumentError -> nil
    end
  end

  defp maybe_atom(_key), do: nil

  defp normalize_label(label), do: label |> to_string() |> String.trim() |> String.downcase()

  defp ordered_entries(states, order) when is_map(states) and is_list(order) do
    ordered =
      order
      |> Enum.map(&to_string/1)
      |> Enum.flat_map(fn name ->
        if Map.has_key?(states, name), do: [{name, Map.fetch!(states, name)}], else: []
      end)

    present = MapSet.new(Enum.map(ordered, &elem(&1, 0)))

    ordered ++
      Enum.reject(states, fn {name, _value} -> MapSet.member?(present, to_string(name)) end)
  end

  defp ordered_entries(states, _order) when is_map(states), do: Map.to_list(states)
  defp ordered_entries(_states, _order), do: []
end
