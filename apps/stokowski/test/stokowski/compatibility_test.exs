defmodule Stokowski.CompatibilityTest do
  use ExUnit.Case, async: true

  alias Stokowski.Compatibility

  test "every compatibility row has provenance, a fixture, a disposition, and an ADR" do
    root = Path.expand("../../../..", __DIR__)
    ledger = Path.expand("../fixtures/compatibility_ledger.yaml", __DIR__)

    assert :ok = Compatibility.validate(ledger, root)
    assert {:ok, rows} = YamlElixir.read_from_file(ledger)
    assert length(rows) >= 12
    assert Enum.any?(rows, &(&1["source"] == "vendor/stokowski@b80db05"))
    assert Enum.any?(rows, &(&1["source"] == "vendor/Continuum@237dfbb"))
    assert Enum.any?(rows, &(&1["source"] == "codex-cli@0.154.0"))

    assert Enum.any?(rows, fn row ->
             row["id"] == "lc-priority-metadata" and row["disposition"] == "defer"
           end)

    assert Enum.any?(rows, fn row ->
             row["id"] == "linear-assignee" and row["disposition"] == "defer"
           end)

    Enum.each(rows, fn row ->
      assert File.regular?(Path.join(root, row["adr"]))
    end)
  end

  @tag :tmp_dir
  test "reports a missing fixture by row identifier", %{tmp_dir: tmp_dir} do
    ledger = Path.join(tmp_dir, "ledger.yaml")

    File.write!(ledger, """
    - id: missing
      source: codex-cli@0.154.0
      fixture: absent.yaml
      input: input
      output: output
      disposition: preserve
      adr: decision.adoc
    """)

    assert {:error, {:missing_fixture, "missing"}} =
             Compatibility.validate(ledger, tmp_dir)
  end

  @tag :tmp_dir
  test "rejects an empty or non-list ledger", %{tmp_dir: tmp_dir} do
    ledger = Path.join(tmp_dir, "ledger.yaml")

    File.write!(ledger, "[]\n")
    assert {:error, :ledger_must_not_be_empty} = Compatibility.validate(ledger, tmp_dir)

    File.write!(ledger, "{}\n")
    assert {:error, :ledger_must_be_a_list} = Compatibility.validate(ledger, tmp_dir)
  end

  @tag :tmp_dir
  test "reports an unavailable vendored source revision by row identifier", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "fixture.yaml"), "fixture")
    File.write!(Path.join(tmp_dir, "decision.adoc"), "decision")

    File.write!(Path.join(tmp_dir, "ledger.yaml"), """
    - id: missing-source
      source: vendor/stokowski@deadbeef
      fixture: fixture.yaml
      input: input
      output: output
      disposition: preserve
      adr: decision.adoc
    """)

    assert {:error, {:missing_source, "missing-source"}} =
             Compatibility.validate(Path.join(tmp_dir, "ledger.yaml"), tmp_dir)
  end

  test "captures the deferred prompt context fixture" do
    fixture = Path.expand("../fixtures/prompts/context.yaml", __DIR__)
    assert {:ok, context} = YamlElixir.read_from_file(fixture)
    assert context["issue"]["identifier"] == "EXT-57"
    assert context["is_rework"]
    assert context["review_comments"] == ["Keep Codex current."]
  end

  test "captures deferred Linear response edge cases" do
    fixture = Path.expand("../fixtures/linear/responses.yaml", __DIR__)
    assert {:ok, responses} = YamlElixir.read_from_file(fixture)
    assert responses["assignee"] == "me"
    assert Enum.at(responses["pages"], 0)["nodes"] |> Enum.at(1) == nil
    assert Enum.at(responses["pages"], 1)["nodes"] == "malformed"
    assert Enum.at(responses["pages"], 1)["errors"] == [%{"message" => "partial fixture error"}]
  end

  @tag :tmp_dir
  test "rejects nil, empty, whitespace, and non-string required values", %{tmp_dir: tmp_dir} do
    fixture = Path.join(tmp_dir, "fixture.yaml")
    adr = Path.join(tmp_dir, "decision.adoc")
    ledger = Path.join(tmp_dir, "ledger.yaml")

    File.write!(fixture, "fixture")
    File.write!(adr, "decision")

    row = %{
      "id" => "valid",
      "source" => "codex-cli@0.154.0",
      "fixture" => "fixture.yaml",
      "input" => "input",
      "output" => "output",
      "disposition" => "preserve",
      "adr" => "decision.adoc"
    }

    for field <- ~w(id source fixture input output disposition adr),
        value <- [nil, "", " \t", 12] do
      File.write!(ledger, Jason.encode!([Map.put(row, field, value)]))

      assert {:error, {:invalid_required_fields, _row_id, [^field]}} =
               Compatibility.validate(ledger, tmp_dir)
    end
  end

  test "pins the Linear CLI metadata dependency to EXT-64" do
    fixture = Path.expand("../fixtures/trackers/lc-metadata.yaml", __DIR__)

    assert {:ok, metadata} = YamlElixir.read_from_file(fixture)
    assert metadata["blocked_by"]["identifier"] == "EXT-64"

    assert metadata["blocked_by"]["url"] ==
             "https://linear.app/the-rubyists/issue/EXT-64"
  end

  test "post-baseline feature inventory covers the vendored Stokowski history" do
    root = Path.expand("../../../..", __DIR__)
    vendor = Path.join(root, "vendor/stokowski")

    assert {:ok, inventory} =
             YamlElixir.read_from_file(
               Path.join(
                 root,
                 "apps/stokowski/test/fixtures/compatibility/post-b80-features.yaml"
               )
             )

    baseline = inventory["baseline"]
    pin = inventory["pin"]
    commit_rows = inventory["commits"]
    expected_commits = Enum.map(commit_rows, & &1["sha"])

    assert {checkout, 0} = System.cmd("git", ["-C", vendor, "rev-parse", "HEAD"])
    assert String.trim(checkout) == pin
    assert List.last(expected_commits) == pin
    assert length(expected_commits) == MapSet.size(MapSet.new(expected_commits))

    # actions/checkout intentionally leaves a submodule with only its pinned object.
    # Compare the exact ancestry whenever the baseline object is available locally;
    # the fixture's structural and checkout-pin assertions still run in shallow CI.
    case System.cmd("git", ["-C", vendor, "cat-file", "-e", "#{baseline}^{commit}"],
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        assert {_output, 0} =
                 System.cmd("git", ["-C", vendor, "merge-base", "--is-ancestor", baseline, pin])

        assert {history, 0} =
                 System.cmd("git", ["-C", vendor, "rev-list", "--reverse", "#{baseline}..#{pin}"])

        assert expected_commits == String.split(history)

      {_output, _status} ->
        :ok
    end

    features = inventory["features"]
    feature_ids = MapSet.new(features, & &1["id"])

    referenced_features =
      commit_rows
      |> Enum.flat_map(fn row ->
        assert non_empty_string?(row["summary"])
        assert row["represents"] != []
        assert Enum.all?(row["represents"], &MapSet.member?(feature_ids, &1))
        row["represents"]
      end)
      |> MapSet.new()

    assert referenced_features == feature_ids

    Enum.each(features, fn feature ->
      assert non_empty_string?(feature["id"])
      assert feature["disposition"] in ~w(preserve correct defer)
      assert non_empty_string?(feature["owner"])
      assert non_empty_string?(feature["delivery_phase"])
      assert non_empty_string?(feature["contract"])
      assert feature["sources"] != []
      assert Enum.all?(feature["sources"], &(&1 in expected_commits))
    end)
  end

  defp non_empty_string?(value), do: is_binary(value) and String.trim(value) != ""
end
