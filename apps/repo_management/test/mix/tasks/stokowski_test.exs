defmodule Mix.Tasks.StokowskiTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Stokowski, as: StokowskiTask

  @tag :tmp_dir
  test "accepts omission and environment references in supported YAML forms", %{tmp_dir: tmp_dir} do
    workflows = [
      "tracker: {kind: linear}\n",
      "tracker:\n  api_key: $LINEAR_API_KEY\n",
      ~S(tracker: {api_key: "$CUSTOM_API_KEY"}) <> "\n",
      ~S("tracker": {"api_key": "$QUOTED_KEY"}) <> "\n",
      "projects:\n  - tracker: {api_key: '$PROJECT_API_KEY'}\n"
    ]

    Enum.with_index(workflows, fn workflow, index ->
      path = write_workflow(tmp_dir, index, workflow)
      assert :ok = validate(path)
    end)
  end

  @tag :tmp_dir
  test "rejects literal API keys in alternate YAML forms without revealing them", %{
    tmp_dir: tmp_dir
  } do
    workflows = [
      "tracker:\n  api_key: block-secret\n",
      ~S(tracker: {kind: linear, api_key: "flow-secret"}) <> "\n",
      ~S(tracker: {"api_key": "quoted-key-secret"}) <> "\n",
      ~S(tracker: {"\u0061pi_key": "escaped-key-secret"}) <> "\n",
      "projects:\n  - tracker: {api_key: project-secret}\n",
      "tracker:\n  api_key: $LINEAR_API_KEY\n  api_key: duplicate-secret\n",
      "tracker: {api_key: first-document-secret}\n---\ntracker: {kind: linear}\n"
    ]

    Enum.with_index(workflows, fn workflow, index ->
      path = write_workflow(tmp_dir, index, workflow)

      error =
        assert_raise Mix.Error, ~r/must not contain a literal tracker\.api_key/, fn ->
          validate(path)
        end

      refute Exception.message(error) =~ "secret"
    end)
  end

  @tag :tmp_dir
  test "rejects malformed YAML without revealing its contents", %{tmp_dir: tmp_dir} do
    path = write_workflow(tmp_dir, 0, "tracker: [malformed-secret")

    error =
      assert_raise Mix.Error, ~r/could not safely parse tracker\.api_key/, fn ->
        validate(path)
      end

    refute Exception.message(error) =~ "malformed-secret"
  end

  defp validate(workflow) do
    StokowskiTask.validate_api_key!(workflow)
  end

  defp write_workflow(tmp_dir, index, contents) do
    path = Path.join(tmp_dir, "workflow-#{index}.yaml")
    File.write!(path, contents)
    path
  end
end
