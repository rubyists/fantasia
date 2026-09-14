defmodule Mix.Tasks.StokowskiTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Stokowski, as: StokowskiTask

  @tag :tmp_dir
  test "launches the vendored CLI with the expected process contract", %{tmp_dir: tmp_dir} do
    {root, vendor, invocation} = fake_checkout(tmp_dir, 0)

    output =
      capture_io(fn ->
        StokowskiTask.run(["--dry-run", "--verbose"], root)
      end)

    assert output =~ "fake uv stdout"
    assert output =~ "fake uv stderr"
    assert output =~ "Using Codex 0.154.0 at"

    assert File.read!(invocation) ==
             Enum.join(
               [
                 root,
                 "run",
                 "--project",
                 vendor,
                 "--extra",
                 "web",
                 "--with-editable",
                 vendor,
                 "--",
                 "stokowski",
                 Path.join(root, "workflow.yaml"),
                 "--dry-run",
                 "--verbose"
               ],
               "\n"
             ) <> "\n"

    refute File.exists?(Path.join(vendor, "uv.lock"))
  end

  @tag :tmp_dir
  test "reports a nonzero exit and still removes the generated lockfile", %{tmp_dir: tmp_dir} do
    {root, vendor, _invocation} = fake_checkout(tmp_dir, 23)

    assert_raise Mix.Error, "vendored Stokowski exited with status 23", fn ->
      capture_io(fn -> StokowskiTask.run([], root) end)
    end

    refute File.exists?(Path.join(vendor, "uv.lock"))
  end

  @tag :tmp_dir
  test "accepts omission and environment references in supported YAML forms", %{tmp_dir: tmp_dir} do
    workflows = [
      "tracker: {kind: linear}\n",
      "tracker:\n  api_key: $LINEAR_API_KEY\n",
      ~S(tracker: {api_key: "$CUSTOM_API_KEY"}) <> "\n",
      ~S("tracker": {"api_key": "$QUOTED_KEY"}) <> "\n",
      "projects:\n  - tracker: {api_key: '$PROJECT_API_KEY'}\n"
    ]

    Enum.each(Enum.with_index(workflows), fn {workflow, index} ->
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

    Enum.each(Enum.with_index(workflows), fn {workflow, index} ->
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

  @tag :tmp_dir
  test "rejects Codex version drift without exposing probe output", %{tmp_dir: tmp_dir} do
    {root, _vendor, _invocation} = fake_checkout(tmp_dir, 0, "codex-cli 0.999.0")

    error =
      assert_raise Mix.Error, "repository-managed Codex version does not match mise.toml", fn ->
        StokowskiTask.resolve_codex!(root)
      end

    refute Exception.message(error) =~ "0.999.0"
  end

  @tag :tmp_dir
  test "resolves and verifies the pinned Claude executable", %{tmp_dir: tmp_dir} do
    {root, _vendor, _invocation} = fake_checkout(tmp_dir, 0)

    assert {_claude, "2.1.270"} = StokowskiTask.resolve_runner!(root, "claude")
  end

  @tag :tmp_dir
  test "reads runner pins only from the tools table", %{tmp_dir: tmp_dir} do
    {root, _vendor, _invocation} = fake_checkout(tmp_dir, 0)
    File.write!(Path.join(root, "mise.toml"), "[env]\ncodex = \"0.999.0\"\n")

    assert_raise Mix.Error, "mise.toml [tools] table must declare an exact codex version", fn ->
      StokowskiTask.resolve_codex!(root)
    end
  end

  @tag :tmp_dir
  test "reads runner pins from tools regardless of table order", %{tmp_dir: tmp_dir} do
    {root, _vendor, _invocation} = fake_checkout(tmp_dir, 0)

    File.write!(
      Path.join(root, "mise.toml"),
      "[env]\nFANTASIA_PROBE = \"1\"\n\n[tools]\ncodex = \"0.154.0\"\nclaude = \"2.1.270\"\n"
    )

    assert {_codex, "0.154.0"} = StokowskiTask.resolve_codex!(root)
    assert {_claude, "2.1.270"} = StokowskiTask.resolve_runner!(root, "claude")
  end

  @tag :tmp_dir
  test "accepts prerelease Claude pins", %{tmp_dir: tmp_dir} do
    {root, _vendor, _invocation} = fake_checkout(tmp_dir, 0)
    claude = Path.join(tmp_dir, "bin/claude")

    File.write!(claude, "#!/bin/sh\nprintf '%s\\n' '2.1.270-rc.1 (Claude Code)'\n")
    File.chmod!(claude, 0o755)

    File.write!(
      Path.join(root, "mise.toml"),
      "[tools]\ncodex = \"0.154.0\"\nclaude = \"2.1.270-rc.1\"\n"
    )

    assert {_claude, "2.1.270-rc.1"} = StokowskiTask.resolve_runner!(root, "claude")
  end

  test "provenance fixture describes both verified runners" do
    fixture = Path.expand("../../../../stokowski/test/fixtures/runners/provenance.yaml", __DIR__)
    assert {:ok, provenance} = YamlElixir.read_from_file(fixture)
    assert provenance["resolution"] == "mise which codex"
    assert provenance["verify"] == "codex --version"
    assert provenance["claude"]["resolution"] == "mise which claude"
    assert provenance["claude"]["version"] == "2.1.270"
    assert provenance["claude"]["reject_drift"]
  end

  defp validate(workflow) do
    StokowskiTask.validate_api_key!(workflow)
  end

  defp write_workflow(tmp_dir, index, contents) do
    path = Path.join(tmp_dir, "workflow-#{index}.yaml")
    File.write!(path, contents)
    path
  end

  defp fake_checkout(tmp_dir, exit_status, codex_version \\ "codex-cli 0.154.0") do
    root = Path.join(tmp_dir, "repo")
    vendor = Path.join([root, "vendor", "stokowski"])
    bin = Path.join(tmp_dir, "bin")
    invocation = Path.join(vendor, "invocation.log")

    File.mkdir_p!(vendor)
    File.mkdir_p!(bin)
    File.write!(Path.join(root, "workflow.yaml"), "tracker: {kind: linear}\n")

    File.write!(
      Path.join(root, "mise.toml"),
      "[tools]\ncodex = \"0.154.0\"\nclaude = \"2.1.270\"\n"
    )

    File.write!(Path.join(vendor, "pyproject.toml"), "")

    write_executable!(
      Path.join(bin, "uv"),
      """
      #!/bin/sh
      {
        pwd
        printf '%s\\n' "$@"
      } > "$3/invocation.log"
      : > "$3/uv.lock"
      printf 'fake uv stdout\\n'
      printf 'fake uv stderr\\n' >&2
      exit #{exit_status}
      """
    )

    codex = Path.join(bin, "codex")
    write_executable!(codex, "#!/bin/sh\nprintf '%s\\n' '#{codex_version}'\n")

    claude = Path.join(bin, "claude")
    write_executable!(claude, "#!/bin/sh\nprintf '%s\\n' '2.1.270 (Claude Code)'\n")

    write_executable!(
      Path.join(bin, "mise"),
      """
      #!/bin/sh
      case "$1 $2" in
        "which codex") printf '%s\\n' '#{codex}' ;;
        "which claude") printf '%s\\n' '#{claude}' ;;
        *) exit 2 ;;
      esac
      """
    )

    original_path = System.get_env("PATH")
    System.put_env("PATH", Enum.join([bin, original_path], ":"))

    on_exit(fn ->
      if original_path do
        System.put_env("PATH", original_path)
      else
        System.delete_env("PATH")
      end
    end)

    {root, vendor, invocation}
  end

  defp write_executable!(path, contents) do
    File.write!(path, contents)
    File.chmod!(path, 0o755)
  end
end
