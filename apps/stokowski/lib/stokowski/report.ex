defmodule Stokowski.Report do
  @moduledoc "Safe structured-report codec and deterministic markdown projection."

  alias Stokowski.Domain.ReportResult

  @doc "Decode a report map or JSON document without executing model content."
  @spec decode(map() | binary()) :: {:ok, ReportResult.t()} | {:error, term()}
  def decode(data) when is_map(data), do: {:ok, project(data)}

  def decode(data) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, map} when is_map(map) -> {:ok, project(map)}
      {:ok, _} -> {:error, :report_mapping_required}
      {:error, reason} -> {:error, {:invalid_report_json, reason}}
    end
  end

  def decode(_), do: {:error, :invalid_report}

  @doc "Convert decoded or raw report data to the durable provider-neutral value."
  @spec project(map() | ReportResult.t()) :: ReportResult.t()
  def project(%ReportResult{} = report), do: report

  def project(data) when is_map(data) do
    %ReportResult{
      verdict: field(data, :verdict),
      headline: field(data, :headline),
      summary: field(data, :summary),
      classification: field(data, :classification),
      confidence: field(data, :confidence),
      key_points: list_field(data, :key_points),
      claims: list_field(data, :claims),
      data_sources: list_field(data, :data_sources),
      verification: list_field(data, :verification),
      changes: list_field(data, :changes),
      artifacts: list_field(data, :artifacts),
      risks: list_field(data, :risks),
      assumptions: list_field(data, :assumptions),
      open_questions: list_field(data, :open_questions),
      next: field(data, :next),
      next_steps: list_field(data, :next_steps)
    }
  end

  @doc "Render a structured report with its recommendation before evidence."
  @spec render(map() | ReportResult.t() | nil, keyword()) :: binary()
  def render(data, opts \\ [])

  def render(nil, opts) do
    fallback = Keyword.get(opts, :fallback, "")

    [
      "## #{Keyword.get(opts, :state, "state")} — no structured report",
      "",
      "The agent produced no structured report; the result is unverified.",
      "",
      fallback
    ]
    |> Enum.join("\n")
  end

  def render(data, opts) do
    report = project(data)
    lines = recommendation(report) ++ ["", "### Structured report"]
    lines = add_scalar(lines, "Summary", report.summary)
    lines = add_scalar(lines, "Headline", report.headline)
    lines = add_scalar(lines, "Classification", report.classification)
    lines = add_scalar(lines, "Confidence", report.confidence)
    lines = add_claims(lines, report.claims)
    lines = add_evidence_coverage(lines, report.claims)
    lines = add_data_sources(lines, report.data_sources)
    lines = add_changes(lines, report.changes)
    lines = add_verification(lines, report.verification)
    lines = add_artifacts(lines, report.artifacts, Keyword.get(opts, :uploaded, %{}))
    lines = add_bullets(lines, "Assumptions made", report.assumptions)
    lines = add_bullets(lines, "Risks", report.risks)
    lines = add_bullets(lines, "Open questions", report.open_questions)
    Enum.join(lines ++ footer(opts), "\n")
  end

  @doc "The report contract inserted into every lifecycle prompt."
  @spec contract() :: [binary()]
  def contract do
    [
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
  end

  @doc "Load the report file first, then a fenced JSON block from runner output."
  def load(workspace, fallback \\ "") do
    path = Path.join(workspace, ".stokowski/report.json")

    with {:ok, body} <- File.read(path), {:ok, report} <- decode(body) do
      {:ok, report}
    else
      _ ->
        Regex.scan(~r/```(?:json)?\s*(\{.*?\})\s*```/s, fallback, capture: :all_but_first)
        |> Enum.find_value({:error, :report_missing}, fn [json] ->
          case Jason.decode(json) do
            {:ok, map} when is_map(map) ->
              if report_shape?(map), do: {:ok, project(map)}

            _ ->
              nil
          end
        end)
    end
  end

  @doc "Discard a consumed report without making the operation fail on absence."
  def discard(workspace) do
    workspace
    |> Path.join(".stokowski/report.json")
    |> File.rm()
    |> case do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp recommendation(%ReportResult{verdict: verdict, next: next, next_steps: steps} = report) do
    {icon, heading} = verdict_heading(verdict)
    lines = ["> ## #{icon} #{heading}"]

    lines =
      if next not in [:unavailable, nil, ""], do: lines ++ [">", "> #{format(next)}"], else: lines

    points =
      if report.key_points == [],
        do: Enum.map(report.claims, &field_any(&1, :claim)),
        else: Enum.map(report.key_points, &clean/1)

    points = Enum.reject(points, &(&1 in [nil, ""]))

    lines =
      if points == [],
        do: lines,
        else: lines ++ [">", "> **Why**"] ++ Enum.map(points, &"> - #{clean(&1)}")

    claims = Enum.filter(report.claims, &is_map/1)
    unsourced = Enum.count(claims, &(not (present?(&1, :evidence) and present?(&1, :source))))

    lines =
      if unsourced > 0 do
        lines ++ [">", "> ⚠️ #{unsourced} of #{length(claims)} claims unsourced"]
      else
        lines
      end

    confidence = format(report.confidence) |> String.downcase()

    lines =
      if confidence != "" do
        mark = %{"high" => "●●●", "medium" => "●●○", "low" => "●○○"} |> Map.get(confidence, "")
        lines ++ [">", "> confidence #{mark} #{confidence}"]
      else
        lines
      end

    case steps do
      [] ->
        lines

      values ->
        numbered =
          values
          |> Enum.with_index(1)
          |> Enum.map(fn {value, index} -> "> #{index}. #{clean(value)}" end)

        lines ++ [">", "> **Next steps**"] ++ numbered
    end
  end

  defp verdict_heading(value) do
    case value |> format() |> String.downcase() |> String.replace("_", "-") do
      "approve" -> {"✅", "Approve"}
      "complete" -> {"✅", "Complete"}
      "stands-up" -> {"✅", "Stands up"}
      "rework" -> {"🔄", "Needs rework"}
      "needs-rework" -> {"🔄", "Needs rework"}
      "request-changes" -> {"🔄", "Request changes"}
      "cannot-verify" -> {"⛔", "Cannot verify"}
      "not-reproducible" -> {"⛔", "Not reproducible"}
      "blocked" -> {"⛔", "Blocked"}
      "" -> {"⚠️", "No verdict"}
      other -> {"⚠️", titleize(other)}
    end
  end

  defp add_scalar(lines, _heading, value) when value in [:unavailable, nil, ""], do: lines
  defp add_scalar(lines, heading, value), do: lines ++ ["", "### #{heading}", "", format(value)]

  defp add_claims(lines, []), do: lines

  defp add_claims(lines, claims) do
    rows =
      claims
      |> Enum.filter(&is_map/1)
      |> Enum.map(fn claim ->
        [
          field_any(claim, :claim),
          required_field(claim, :evidence),
          required_field(claim, :source),
          field_any(claim, :confidence)
        ]
        |> Enum.map(&table_cell/1)
      end)

    if rows == [],
      do: lines,
      else:
        lines ++
          [
            "",
            "### Findings",
            "",
            "| Claim | Evidence | Source | Confidence |",
            "| --- | --- | --- | --- |"
          ] ++ Enum.map(rows, &("| " <> Enum.join(&1, " | ") <> " |"))
  end

  defp add_evidence_coverage(lines, []), do: lines

  defp add_evidence_coverage(lines, claims) do
    claims = Enum.filter(claims, &is_map/1)
    sourced = Enum.count(claims, &(present?(&1, :evidence) and present?(&1, :source)))
    total = length(claims)
    warning = if sourced == total, do: "", else: " ⚠️ unsourced claims remain"

    lines ++
      [
        "",
        "### Evidence coverage",
        "",
        "#{sourced}/#{total} claims have both evidence and source.#{warning}"
      ]
  end

  defp add_data_sources(lines, []), do: lines

  defp add_data_sources(lines, sources) do
    rows =
      sources
      |> Enum.filter(&is_map/1)
      |> Enum.map(fn source ->
        verification =
          if present?(source, :how_verified),
            do: field_any(source, :how_verified),
            else: "⚠️ not verified"

        [field_any(source, :name), verification] |> Enum.map(&table_cell/1)
      end)

    if rows == [],
      do: lines,
      else:
        lines ++
          ["", "### Data sources", "", "| Source | How verified |", "| --- | --- |"] ++
          Enum.map(rows, &("| " <> Enum.join(&1, " | ") <> " |"))
  end

  defp add_changes(lines, []), do: lines
  defp add_changes(lines, changes), do: add_map_table(lines, "Changes", changes, [:file, :what])

  defp add_verification(lines, []), do: lines

  defp add_verification(lines, checks) do
    rows =
      checks
      |> Enum.filter(&is_map/1)
      |> Enum.map(fn check ->
        result = field_any(check, :result) |> format() |> String.downcase()
        mark = if result in ["pass", "passed", "ok"], do: "✅", else: "❌"

        [field_any(check, :check), "#{mark} #{result}", field_any(check, :detail)]
        |> Enum.map(&table_cell/1)
      end)

    if rows == [],
      do: lines,
      else:
        lines ++
          ["", "### Verification", "", "| Check | Result | Detail |", "| --- | --- | --- |"] ++
          Enum.map(rows, &("| " <> Enum.join(&1, " | ") <> " |"))
  end

  defp add_artifacts(lines, [], _uploaded), do: lines

  defp add_artifacts(lines, artifacts, uploaded) do
    rendered =
      artifacts
      |> Enum.filter(&is_map/1)
      |> Enum.map(fn artifact ->
        file = field_any(artifact, :file) |> format()
        caption = field_any(artifact, :caption) |> format()
        url = Map.get(uploaded, file)

        caption = if caption == "", do: file, else: caption

        if url && String.ends_with?(String.downcase(file), ".png"),
          do: "![#{caption}](#{url})",
          else: "[#{caption}](#{url || file})"
      end)

    if rendered == [],
      do: lines,
      else: lines ++ ["", "### Evidence", ""] ++ Enum.map(rendered, &("- " <> &1))
  end

  defp add_bullets(lines, _heading, []), do: lines

  defp add_bullets(lines, heading, values),
    do: lines ++ ["", "### #{heading}", ""] ++ Enum.map(values, &("- " <> clean(&1)))

  defp add_map_table(lines, heading, values, fields) do
    rows =
      values
      |> Enum.filter(&is_map/1)
      |> Enum.map(fn value -> Enum.map(fields, &(field_any(value, &1) |> table_cell())) end)

    if rows == [],
      do: lines,
      else:
        lines ++
          [
            "",
            "### #{heading}",
            "",
            "| " <> Enum.map_join(fields, " | ", &titleize(to_string(&1))) <> " |",
            "| " <> Enum.map_join(fields, " | ", fn _ -> "---" end) <> " |"
          ] ++ Enum.map(rows, &("| " <> Enum.join(&1, " | ") <> " |"))
  end

  defp footer(opts) do
    case Keyword.get(opts, :usage) do
      %{total_tokens: tokens, cost_usd: cost} ->
        [
          "",
          "_Usage: #{format_number(tokens)} tokens · $#{:erlang.float_to_binary(cost * 1.0, decimals: 2)}_"
        ]

      _ ->
        []
    end
  end

  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key), :unavailable))
  defp field_any(map, key), do: field(map, key) |> format()
  defp list_field(map, key), do: if(is_list(field(map, key)), do: field(map, key), else: [])
  defp present?(map, key), do: field(map, key) |> format() |> String.trim() != ""

  defp required_field(map, key) do
    if present?(map, key) do
      field_any(map, key)
    else
      case key do
        :evidence -> "⚠️ no evidence given"
        :source -> "⚠️ unsourced"
        _ -> "⚠️ missing"
      end
    end
  end

  defp report_shape?(map),
    do:
      Enum.any?([:summary, :claims, :verdict, :data_sources, :verification], fn key ->
        Map.has_key?(map, key) or Map.has_key?(map, Atom.to_string(key))
      end)

  defp clean(value), do: value |> format() |> String.replace("\n", " ")
  defp table_cell(value), do: value |> clean() |> String.replace("|", "\\|")
  defp format(:unavailable), do: ""
  defp format(nil), do: ""
  defp format(value) when is_binary(value), do: value
  defp format(value) when is_list(value), do: Enum.map_join(value, ", ", &format/1)
  defp format(value) when is_map(value), do: inspect(value)
  defp format(value), do: to_string(value)

  defp titleize(value),
    do:
      value
      |> String.replace("_", " ")
      |> String.split()
      |> Enum.map_join(" ", &String.capitalize/1)

  defp format_number(value) when is_integer(value),
    do: value |> Integer.to_string() |> String.replace(~r/(?<=\d)(?=(\d{3})+$)/, ",")

  defp format_number(value), do: format(value)
end
