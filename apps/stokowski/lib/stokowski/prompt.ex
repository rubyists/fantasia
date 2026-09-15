defmodule Stokowski.Prompt do
  @moduledoc "Safe, deliberately small prompt renderer and lifecycle assembler."

  use Continuum.Pure

  alias Stokowski.Domain.{Issue, Phase, PhaseState, WorkflowSnapshot}

  @report_contract [
    "### Evidence",
    "",
    "Write screenshots, recordings, and exported evidence under `$STOKOWSKI_ARTIFACTS`.",
    "Do not leave evidence files elsewhere in the repository.",
    "",
    "### Structured reporting",
    "",
    "Write `.stokowski/report.json` in the workspace root before finishing.",
    "It must be valid JSON with these fields:",
    "",
    "- `summary`: concise result",
    "- `headline`: the single most important result",
    "- `classification`: the kind of work performed",
    "- `confidence`: honest confidence in the conclusion",
    "- `key_points`: the evidence chain behind the recommendation",
    "- `claims`: claim, evidence, source, and confidence for each finding",
    "- `data_sources`: source and how it was independently verified",
    "- `verification`: command, pass/fail result, and detail",
    "- `artifacts`: bounded evidence files and captions",
    "- `assumptions`: decisions made without direct evidence",
    "- `risks`: remaining failure modes",
    "- `open_questions`: unresolved questions",
    "- `verdict`: the supported recommendation",
    "- `next`: what should happen next",
    "- `next_steps`: ordered concrete actions",
    "",
    "Do not omit uncertainty or replace evidence with model confidence."
  ]

  @token ~r/(\{\{.*?\}\}|\{%.*?%\})/s

  @doc "Render the supported prompt subset without evaluating arbitrary code."
  @spec render(binary(), map()) :: binary()
  def render(template, context) when is_binary(template) and is_map(context) do
    template
    |> tokenize()
    |> render_nodes(context)
    |> List.flatten()
    |> Enum.join()
  end

  @doc "Build the nested and flat context accepted by legacy prompt examples."
  @spec context(Issue.t() | map(), map()) :: map()
  def context(issue, lifecycle \\ %{}) do
    issue = issue_map(issue)

    issue_context =
      issue
      |> Enum.map(fn {key, value} -> {to_string(key), display_value(value)} end)
      |> Map.new()

    flat =
      issue_context
      |> Enum.map(fn {key, value} -> {"issue_#{key}", value} end)
      |> Map.new()

    Map.merge(%{"issue" => issue_context}, flat)
    |> Map.merge(%{"lifecycle" => lifecycle})
    |> Map.merge(lifecycle)
  end

  @doc "Assemble global prompts, the selected phase prompt, and lifecycle data."
  @spec assemble(WorkflowSnapshot.t(), Issue.t() | map(), PhaseState.t() | binary(), keyword()) ::
          binary()
  def assemble(
        %WorkflowSnapshot{prompts: prompts, graph: graph} = snapshot,
        issue,
        state,
        opts \\ []
      ) do
    phase_name = if is_binary(state), do: state, else: state.phase
    phase = Map.get(graph, phase_name)
    lifecycle = lifecycle_data(snapshot, issue, state, phase, opts)
    ctx = context(issue, lifecycle)

    global = prompts |> Map.get(:global, Map.get(prompts, "global", [])) |> List.wrap()

    legacy = Map.get(prompts, :legacy, Map.get(prompts, "legacy", :unavailable))

    legacy =
      if is_binary(legacy) and legacy != "" do
        [render(legacy, ctx)]
      else
        []
      end

    phase_prompt =
      prompts |> Map.get(:phases, Map.get(prompts, "phases", %{})) |> Map.get(phase_name, "")

    (Enum.map(global, &render(&1, ctx)) ++
       legacy ++
       if(is_binary(phase_prompt) and phase_prompt != "",
         do: [render(phase_prompt, ctx)],
         else: []
       ) ++
       [lifecycle_markdown(lifecycle) || ""])
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  @doc "Build the deterministic lifecycle data used by every assembled prompt."
  @spec lifecycle_data(
          WorkflowSnapshot.t(),
          Issue.t() | map(),
          PhaseState.t() | binary(),
          Phase.t() | nil,
          keyword()
        ) :: map()
  def lifecycle_data(snapshot, issue, state, phase, opts \\ []) do
    state = if is_binary(state), do: %PhaseState{phase: state}, else: state
    comments = normalize_comments(Keyword.get(opts, :comments, []))
    max_comments = Keyword.get(opts, :max_comments, 20)
    max_chars = Keyword.get(opts, :max_chars, 12_000)
    selected = comments |> Enum.take(max_comments) |> comments_markdown()
    selected = truncate(selected, max_chars)

    %{
      "phase" => state.phase,
      "state" => state.phase,
      "run" => state.run,
      "attempt" => state.attempt,
      "workflow" => snapshot.workflow,
      "workflow_fingerprint" => snapshot.fingerprint,
      "entry_phase" => snapshot.entry_phase,
      "transitions" => state.transitions,
      "available_transitions" => if(phase, do: phase.transitions, else: %{}),
      "rework" => Keyword.get(opts, :rework, false),
      "rework_feedback" => Keyword.get(opts, :rework_feedback, state.feedback),
      "comments" => selected,
      "comment_count" => length(comments),
      "comments_truncated" =>
        length(comments) > max_comments or selected != comments_markdown(comments),
      "issue" => issue_map(issue)
    }
  end

  @doc "Render the lifecycle section and the structured report contract."
  def lifecycle_markdown(data) when is_map(data) do
    issue = Map.get(data, "issue", %{})

    lines = [
      "---",
      "<!-- AUTO-GENERATED BY FANTASIA — DO NOT EDIT -->",
      "",
      "## Lifecycle Context",
      "",
      "- **Issue:** #{value(issue, "identifier")} — #{value(issue, "title")}",
      "- **State:** #{value(data, "phase")}",
      "- **Run:** #{value(data, "run")}",
      "- **Attempt:** #{value(data, "attempt")}",
      "- **Workflow:** #{value(data, "workflow")}",
      ""
    ]

    lines =
      if truthy?(Map.get(data, "rework")) do
        lines ++
          [
            "### Rework",
            "",
            "This is a **rework run**.",
            "",
            "**Feedback:**",
            "",
            value(data, "rework_feedback"),
            ""
          ]
      else
        lines
      end

    lines =
      case Map.get(data, "comments", "") do
        "" -> lines
        comments -> lines ++ ["### Recent Activity", "", comments, ""]
      end

    transitions = Map.get(data, "available_transitions", %{})

    lines =
      if map_size(transitions) > 0 do
        transition_lines =
          transitions
          |> Enum.sort_by(fn {trigger, _target} -> to_string(trigger) end)
          |> Enum.map(fn {trigger, target} -> "- `#{trigger}` → **#{target}**" end)

        lines ++
          ["### Transitions", ""] ++ transition_lines ++ [""]
      else
        lines
      end

    (lines ++ @report_contract)
    |> Enum.join("\n")
  end

  defp tokenize(template), do: Regex.split(@token, template, include_captures: true)

  defp render_nodes(tokens, context), do: parse_nodes(tokens, context, []) |> elem(0)

  defp parse_nodes([], _context, _stop), do: {[], [], nil}

  defp parse_nodes([token | rest], context, stop) do
    case directive(token) do
      {:if, expression} ->
        {truthy_nodes, after_truthy, marker} = parse_nodes(rest, context, [:else, :endif])

        {false_nodes, after_false, false_marker} =
          case marker do
            :else ->
              parse_nodes(drop_first(after_truthy), context, [:endif])

            _ ->
              {[], after_truthy, marker}
          end

        remaining =
          cond do
            marker == :endif -> drop_first(after_truthy)
            false_marker == :endif -> drop_first(after_false)
            true -> after_false
          end

        chosen = if truthy?(resolve(expression, context)), do: truthy_nodes, else: false_nodes
        {tail, remaining, stop_marker} = parse_nodes(remaining, context, stop)
        {chosen ++ tail, remaining, stop_marker}

      {:else, _} ->
        if :else in stop do
          {[], [token | rest], :else}
        else
          {tail, remaining, marker} = parse_nodes(rest, context, stop)
          {[token | tail], remaining, marker}
        end

      {:endif, _} ->
        if :endif in stop do
          {[], [token | rest], :endif}
        else
          {tail, remaining, marker} = parse_nodes(rest, context, stop)
          {[token | tail], remaining, marker}
        end

      :text ->
        {tail, remaining, marker} = parse_nodes(rest, context, stop)
        {[token | tail], remaining, marker}

      :expression ->
        {tail, remaining, marker} = parse_nodes(rest, context, stop)
        {[render_expression(String.slice(token, 2..-3//1), context) | tail], remaining, marker}
    end
  end

  defp drop_first([_ | rest]), do: rest
  defp drop_first([]), do: []

  defp directive(token) do
    cond do
      String.starts_with?(token, "{{") ->
        :expression

      String.starts_with?(token, "{%") ->
        expression =
          token |> String.trim_leading("{%") |> String.trim_trailing("%}") |> String.trim()

        case String.split(expression, ~r/\s+/, parts: 2) do
          ["if", condition] -> {:if, condition}
          ["else"] -> {:else, nil}
          ["endif"] -> {:endif, nil}
          _ -> :text
        end

      true ->
        :text
    end
  end

  defp render_expression(expression, context) do
    expression
    |> String.trim()
    |> String.split("|", trim: true)
    |> case do
      [path | filters] ->
        filters
        |> Enum.reduce(resolve(String.trim(path), context), fn filter, value ->
          apply_filter(String.trim(filter), value)
        end)
        |> format_value()

      _ ->
        ""
    end
  end

  defp apply_filter("lower", value), do: lower(value)
  defp apply_filter("lower()", value), do: lower(value)
  defp apply_filter(_unknown, value), do: value

  defp lower(value) when is_list(value), do: Enum.map(value, &lower/1)
  defp lower(value) when is_binary(value), do: String.downcase(value)
  defp lower(value), do: value

  defp resolve(expression, context) do
    expression = String.trim(expression)

    cond do
      expression in ["true", "True"] ->
        true

      expression in ["false", "False"] ->
        false

      expression in ["none", "None", "nil"] ->
        nil

      String.starts_with?(expression, "\"") and String.ends_with?(expression, "\"") ->
        String.slice(expression, 1..-2//1)

      true ->
        expression
        |> String.split(".")
        |> Enum.reduce(context, fn key, value -> lookup(value, key) end)
    end
  end

  defp lookup(value, key) when is_map(value),
    do: Map.get(value, key, Map.get(value, safe_atom(key), ""))

  defp lookup(_value, _key), do: ""

  defp safe_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp format_value(:unavailable), do: ""
  defp format_value({:unavailable, _reason}), do: ""
  defp format_value(nil), do: ""
  defp format_value(true), do: "true"
  defp format_value(false), do: "false"
  defp format_value(value) when is_list(value), do: Enum.map_join(value, ", ", &format_value/1)
  defp format_value(value) when is_map(value), do: inspect(value)
  defp format_value(value), do: to_string(value)

  defp issue_map(%_{} = issue), do: issue |> Map.from_struct() |> issue_map()

  defp issue_map(issue) when is_map(issue),
    do: Map.new(issue, fn {key, value} -> {to_string(key), display_value(value)} end)

  defp issue_map(_), do: %{}

  defp display_value(:unavailable), do: ""
  defp display_value({:unavailable, _}), do: ""
  defp display_value(value), do: value

  defp value(map, key), do: map |> Map.get(key, "") |> format_value()

  defp truthy?(value),
    do: value not in [nil, false, "", [], %{}, :unavailable, {:unavailable, :not_provided}]

  defp normalize_comments(comments) do
    comments
    |> Enum.map(fn comment ->
      comment = if is_struct(comment), do: Map.from_struct(comment), else: comment

      %{
        body: to_string(Map.get(comment, :body, Map.get(comment, "body", ""))),
        author: author_value(comment),
        created_at:
          comment
          |> Map.get(
            :created_at,
            Map.get(
              comment,
              :createdAt,
              Map.get(comment, "createdAt", Map.get(comment, "created_at", :unavailable))
            )
          )
          |> display_value()
          |> format_value()
      }
    end)
    |> Enum.reject(&(&1.body == "" or machine_comment?(&1.body)))
    |> Enum.sort_by(&{&1.created_at, &1.author, &1.body})
  end

  defp machine_comment?(body),
    do: String.contains?(body, "<!-- stokowski:") or String.contains?(body, "<!-- fantasia:v1:")

  defp author_value(comment) do
    direct = Map.get(comment, :author, Map.get(comment, "author", :unavailable))

    actor =
      Map.get(comment, :user, Map.get(comment, "user")) ||
        Map.get(comment, :botActor, Map.get(comment, "botActor")) ||
        Map.get(comment, :externalUser, Map.get(comment, "externalUser"))

    value =
      if is_map(actor),
        do:
          Map.get(
            actor,
            "displayName",
            Map.get(
              actor,
              :displayName,
              Map.get(actor, "name", Map.get(actor, :name, :unavailable))
            )
          ),
        else: direct

    value
    |> display_value()
    |> format_value()
    |> case do
      "" -> "unknown author"
      value -> value
    end
  end

  defp comments_markdown([]), do: ""

  defp comments_markdown(comments) do
    Enum.map_join(comments, "\n", fn comment ->
      [
        "**",
        comment.author,
        "**",
        if(comment.created_at != "", do: " · " <> comment.created_at, else: ""),
        "\n\n",
        comment.body
      ]
      |> List.flatten()
      |> Enum.join()
    end)
  end

  defp truncate(value, max) when byte_size(value) <= max, do: value
  defp truncate(value, max), do: binary_part(value, 0, max) <> "\n\n[comments truncated]"
end
