defmodule Stokowski.Compatibility do
  @moduledoc """
  Validates the Phase 0 compatibility ledger and its fixture ownership.
  """

  @required_fields ~w(id source fixture input output disposition adr)
  @dispositions ~w(preserve correct defer)
  @vendor_source ~r/^vendor\/([A-Za-z0-9_.-]+)@([0-9a-f]{7,40})$/

  @spec validate(Path.t(), Path.t()) :: :ok | {:error, term()}
  def validate(ledger_path, repository_root) do
    with {:ok, rows} <- YamlElixir.read_from_file(ledger_path),
         true <- is_list(rows) or {:error, :ledger_must_be_a_list},
         :ok <- validate_rows(rows, repository_root) do
      :ok
    end
  end

  defp validate_rows(rows, repository_root) do
    if rows == [] do
      {:error, :ledger_must_not_be_empty}
    else
      validate_non_empty_rows(rows, repository_root)
    end
  end

  defp validate_non_empty_rows(rows, repository_root) do
    Enum.reduce_while(rows, MapSet.new(), fn row, ids ->
      case validate_row(row, repository_root) do
        :ok ->
          if MapSet.member?(ids, row["id"]) do
            {:halt, {:error, {:duplicate_id, row["id"]}}}
          else
            {:cont, MapSet.put(ids, row["id"])}
          end

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      %MapSet{} -> :ok
      error -> error
    end
  end

  defp validate_row(row, repository_root) when is_map(row) do
    missing = @required_fields -- Map.keys(row)
    invalid = Enum.reject(@required_fields, &non_empty_string?(row[&1]))

    cond do
      missing != [] ->
        {:error, {:missing_fields, row["id"], missing}}

      invalid != [] ->
        {:error, {:invalid_required_fields, row["id"], invalid}}

      row["disposition"] not in @dispositions ->
        {:error, {:invalid_disposition, row["id"]}}

      not valid_source?(row["source"]) ->
        {:error, {:invalid_source, row["id"]}}

      not source_revision_available?(row["source"], repository_root) ->
        {:error, {:missing_source, row["id"]}}

      not File.regular?(Path.join(repository_root, row["fixture"])) ->
        {:error, {:missing_fixture, row["id"]}}

      not File.regular?(Path.join(repository_root, row["adr"])) ->
        {:error, {:missing_adr, row["id"]}}

      true ->
        :ok
    end
  end

  defp validate_row(_row, _repository_root), do: {:error, :row_must_be_a_map}

  defp non_empty_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp non_empty_string?(_value), do: false

  defp valid_source?(source) when is_binary(source) do
    Regex.match?(@vendor_source, source) or
      Regex.match?(~r/^codex-cli@[0-9]+\.[0-9]+\.[0-9]+$/, source)
  end

  defp valid_source?(_source), do: false

  defp source_revision_available?(source, repository_root) do
    case Regex.run(@vendor_source, source, capture: :all_but_first) do
      [vendor_name, revision] ->
        vendor_path = Path.join([repository_root, "vendor", vendor_name])
        git_revision_available?(vendor_path, revision)

      nil ->
        true
    end
  end

  defp git_revision_available?(vendor_path, revision) do
    with git when is_binary(git) <- System.find_executable("git"),
         true <- File.dir?(vendor_path),
         {_output, 0} <-
           System.cmd(git, ["-C", vendor_path, "cat-file", "-e", "#{revision}^{commit}"],
             stderr_to_stdout: true
           ) do
      true
    else
      _ -> false
    end
  end
end
