defmodule Stokowski.Compatibility do
  @moduledoc """
  Validates the Phase 0 compatibility ledger and its fixture ownership.
  """

  @required_fields ~w(id source fixture input output disposition adr)
  @dispositions ~w(preserve correct defer)

  @spec validate(Path.t(), Path.t()) :: :ok | {:error, term()}
  def validate(ledger_path, repository_root) do
    with {:ok, rows} <- YamlElixir.read_from_file(ledger_path),
         true <- is_list(rows) or {:error, :ledger_must_be_a_list},
         :ok <- validate_rows(rows, repository_root) do
      :ok
    end
  end

  defp validate_rows(rows, repository_root) do
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
    Regex.match?(~r/^(vendor\/[^@]+@[0-9a-f]{7,40}|codex-cli@[0-9]+\.[0-9]+\.[0-9]+)$/, source)
  end

  defp valid_source?(_source), do: false
end
