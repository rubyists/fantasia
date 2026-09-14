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

  test "normalizes the full workflow fixture including a flow merge sequence" do
    path = fixture("config/full-workflow.yaml")

    assert {:ok, workflow} = Workflow.read(path)
    assert {:ok, normalized} = Workflow.normalize(workflow)
    assert normalized["states"]["investigate"]["runner"] == "codex"
    assert normalized["states"]["investigate"]["session"] == "fresh"
    assert normalized["state"]["effort"] == "high"
    assert normalized["state"]["runner"] == "codex"
    assert normalized["state"]["session"] == "fresh"
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

  @tag :tmp_dir
  test "reports flow-style collection aliases explicitly", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "flow-mapping-alias.yaml")
    File.cp!(fixture("config/flow-mapping-alias.yaml"), path)

    assert {:ok, workflow} = Workflow.read(path)
    assert {:error, {:invalid_alias, "defaults"}} = Workflow.normalize(workflow)
  end

  @tag :tmp_dir
  test "rejects plain aliases to flow mappings and sequences", %{tmp_dir: tmp_dir} do
    cases = [
      {"flow-mapping-plain-alias.yaml", "mapping"},
      {"flow-sequence-plain-alias.yaml", "sequence"}
    ]

    Enum.each(cases, fn {name, anchor} ->
      path = Path.join(tmp_dir, name)
      File.cp!(fixture("config/#{name}"), path)

      assert {:ok, workflow} = Workflow.read(path)
      assert {:error, {:invalid_alias, ^anchor}} = Workflow.normalize(workflow)
    end)
  end

  @tag :tmp_dir
  test "derives flow-alias detection from YAML tokens, not scalar text", %{tmp_dir: tmp_dir} do
    workflows = [
      "# see &x {p: 1}\na: &x\n  p: 1\nstate:\n  <<: *x\n  z: 3\n",
      "note: \"use &x {p: 1} here\"\na: &x\n  p: 1\nstate:\n  <<: *x\n  z: 3\n"
    ]

    Enum.each(Enum.with_index(workflows), fn {yaml, index} ->
      path = Path.join(tmp_dir, "flow-alias-text-#{index}.yaml")
      File.write!(path, yaml)

      assert {:ok, workflow} = Workflow.read(path)
      assert {:ok, normalized} = Workflow.normalize(workflow)
      assert normalized["state"] == %{"p" => 1, "z" => 3}
    end)
  end

  @tag :tmp_dir
  test "preserves invalid-key errors when a flow alias is also present", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "flow-alias-invalid-key.yaml")

    File.write!(path, "a: &x {p: 1}\nstate:\n  <<: *x\n1: numeric\n")

    assert {:ok, workflow} = Workflow.read(path)
    assert {:error, {:invalid_key, 1}} = Workflow.normalize(workflow)
  end

  @tag :tmp_dir
  test "returns an empty-document error for an empty YAML file", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "empty.yaml")
    File.write!(path, "")

    assert {:ok, workflow} = Workflow.read(path)
    assert {:error, :empty_document} = Workflow.normalize(workflow)
  end

  @tag :tmp_dir
  test "returns the file error when the workflow is missing", %{tmp_dir: tmp_dir} do
    assert {:error, :enoent} = Workflow.read(Path.join(tmp_dir, "missing.yaml"))
  end

  defp fixture(name), do: Path.expand("../fixtures/#{name}", __DIR__)
end
