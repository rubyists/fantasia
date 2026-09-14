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

  test "normalizes the full workflow fixture with string keys" do
    path = fixture("config/full-workflow.yaml")

    assert {:ok, workflow} = Workflow.read(path)
    assert {:ok, normalized} = Workflow.normalize(workflow)
    assert normalized["states"]["investigate"]["runner"] == "codex"
    assert normalized["states"]["investigate"]["session"] == "fresh"
    assert normalized["state"]["effort"] == "high"
    refute Map.has_key?(normalized["state"], "reasoning_effort")
    assert normalized["flags"] == [true, false, nil, 7, 2.5]
    assert byte_size(Workflow.fingerprint(normalized)) == 64
  end

  test "rejects duplicate keys during normalization" do
    assert {:ok, workflow} = Workflow.read(fixture("config/duplicate-keys.yaml"))
    assert {:error, {:duplicate_key, "runner"}} = Workflow.normalize(workflow)
  end

  @tag :tmp_dir
  test "rejects non-string mapping keys without crashing", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "non-string-key.yaml")
    File.write!(path, "1: numeric\n")

    assert {:ok, workflow} = Workflow.read(path)
    assert {:error, {:invalid_key, 1}} = Workflow.normalize(workflow)
  end

  @tag :tmp_dir
  test "rejects duplicate YAML merge keys", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "duplicate-merges.yaml")

    File.write!(
      path,
      "first: &first {runner: codex}\nsecond: &second {session: fresh}\nstate:\n  <<: *first\n  <<: *second\n"
    )

    assert {:ok, workflow} = Workflow.read(path)
    assert {:error, {:duplicate_key, "<<"}} = Workflow.normalize(workflow)
  end

  @tag :tmp_dir
  test "preserves empty mapping and sequence types", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "empty-containers.yaml")
    File.write!(path, "mapping: {}\nsequence: []\nnested:\n  - {}\n  - []\n")

    assert {:ok, workflow} = Workflow.read(path)
    assert {:ok, normalized} = Workflow.normalize(workflow)
    assert normalized["mapping"] == %{}
    assert normalized["sequence"] == []
    assert normalized["nested"] == [%{}, []]
  end

  defp fixture(name), do: Path.expand("../fixtures/#{name}", __DIR__)
end
