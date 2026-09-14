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
end
