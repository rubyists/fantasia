defmodule Stokowski.WorkflowTest do
  use ExUnit.Case, async: true

  alias Stokowski.Workflow

  @tag :tmp_dir
  test "finds API keys in supported YAML forms", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "workflow.yaml")

    File.write!(
      path,
      ~S"""
      "tracker": {"api_key": "$ROOT_API_KEY"}
      projects:
        - tracker: {"\u0061pi_key": "project-secret"}
      """
    )

    assert {:ok, workflow} = Workflow.read(path)

    assert MapSet.new(Workflow.api_key_values(workflow)) ==
             MapSet.new(["$ROOT_API_KEY", "project-secret"])
  end

  @tag :tmp_dir
  test "retains duplicate API keys for validation", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "workflow.yaml")

    File.write!(
      path,
      "tracker:\n  api_key: $LINEAR_API_KEY\n  api_key: duplicate-secret\n"
    )

    assert {:ok, workflow} = Workflow.read(path)

    assert MapSet.new(Workflow.api_key_values(workflow)) ==
             MapSet.new(["$LINEAR_API_KEY", "duplicate-secret"])
  end

  @tag :tmp_dir
  test "returns YAML parse errors", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "workflow.yaml")
    File.write!(path, "tracker: [")

    assert {:error, %YamlElixir.ParsingError{}} = Workflow.read(path)
  end
end
