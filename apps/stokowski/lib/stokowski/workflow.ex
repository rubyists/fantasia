defmodule Stokowski.Workflow do
  @moduledoc """
  Parses Stokowski workflow files.

  Parsed YAML remains opaque so duplicate map keys and empty container types
  stay visible to workflow validation.
  """

  @enforce_keys [:documents]
  defstruct [:documents]

  @opaque t :: %__MODULE__{documents: [term()]}

  @spec read(Path.t()) :: {:ok, t()} | {:error, Exception.t()}
  def read(path) do
    with {:ok, yaml} <- File.read(path),
         {:ok, _documents} <- YamlElixir.read_all_from_string(yaml, maps_as_keywords: true) do
      documents =
        yaml
        |> :yamerl_constr.string(
          detailed_constr: true,
          str_node_as_binary: true,
          keep_duplicate_keys: true
        )
        |> Enum.map(fn {:yamerl_doc, document} -> preserve_shape(document) end)

      {:ok, %__MODULE__{documents: documents}}
    end
  end

  @spec api_key_values(t()) :: [term()]
  def api_key_values(%__MODULE__{documents: documents}) do
    find_api_key_values(documents)
  end

  @doc """
  Converts one parsed document to a deterministic string-keyed map.

  Duplicate keys and multi-document inputs are rejected before normalization,
  so callers never silently lose configuration while converting keyword maps.
  """
  @spec normalize(t()) ::
          {:ok, map()}
          | {:error,
             :multiple_documents
             | {:duplicate_key, binary()}
             | {:invalid_key, term()}
             | {:invalid_merge, :mapping_required}}
  def normalize(%__MODULE__{documents: [document]}), do: normalize_value(document)
  def normalize(%__MODULE__{}), do: {:error, :multiple_documents}

  @spec fingerprint(map()) :: binary()
  def fingerprint(normalized) when is_map(normalized) do
    normalized
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp find_api_key_values({:mapping, entries}) do
    Enum.flat_map(entries, fn
      {"api_key", value} -> [value | find_api_key_values(value)]
      {_key, value} -> find_api_key_values(value)
    end)
  end

  defp find_api_key_values(entries) when is_list(entries),
    do: Enum.flat_map(entries, &find_api_key_values/1)

  defp find_api_key_values(_value), do: []

  defp normalize_value({:mapping, entries}), do: normalize_mapping(entries)
  defp normalize_value(values) when is_list(values), do: normalize_sequence(values)

  defp normalize_value(value), do: {:ok, value}

  defp normalize_mapping(entries) do
    with :ok <- validate_mapping_keys(entries),
         :ok <- reject_duplicate_keys(entries) do
      {merges, explicit} = Enum.split_with(entries, fn {key, _value} -> merge_key?(key) end)

      with {:ok, inherited} <- normalize_merges(merges),
           {:ok, normalized} <- normalize_explicit(explicit) do
        {:ok, Map.merge(inherited, normalized)}
      end
    end
  end

  defp validate_mapping_keys(entries) do
    Enum.reduce_while(entries, :ok, fn
      {key, _value}, :ok when is_binary(key) -> {:cont, :ok}
      {key, _value}, :ok -> {:halt, {:error, {:invalid_key, key}}}
    end)
  end

  defp reject_duplicate_keys(entries) do
    Enum.reduce_while(entries, MapSet.new(), fn {key, _value}, seen ->
      identity = if merge_key?(key), do: "<<", else: key

      if MapSet.member?(seen, identity) do
        {:halt, {:error, {:duplicate_key, identity}}}
      else
        {:cont, MapSet.put(seen, identity)}
      end
    end)
    |> case do
      %MapSet{} -> :ok
      error -> error
    end
  end

  defp merge_key?(key), do: Regex.match?(~r/^<<\d*$/, key)

  defp normalize_merges(entries) do
    Enum.reduce_while(entries, {:ok, %{}}, fn {_key, value}, {:ok, result} ->
      case normalize_value(value) do
        {:ok, normalized} when is_map(normalized) ->
          {:cont, {:ok, Map.merge(result, normalized)}}

        {:ok, _normalized} ->
          {:halt, {:error, {:invalid_merge, :mapping_required}}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  defp normalize_explicit(entries) do
    Enum.reduce_while(entries, {:ok, %{}}, fn {key, value}, {:ok, result} ->
      case normalize_value(value) do
        {:ok, normalized} -> {:cont, {:ok, Map.put(result, key, normalized)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp normalize_sequence(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, result} ->
      case normalize_value(value) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | result]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> then(fn
      {:ok, result} -> {:ok, Enum.reverse(result)}
      error -> error
    end)
  end

  defp preserve_shape({:yamerl_map, :yamerl_node_map, _tag, _location, entries}) do
    {:mapping,
     Enum.map(entries, fn {key, value} -> {preserve_shape(key), preserve_shape(value)} end)}
  end

  defp preserve_shape({:yamerl_seq, :yamerl_node_seq, _tag, _location, values, _count}) do
    Enum.map(values, &preserve_shape/1)
  end

  defp preserve_shape({:yamerl_null, _node, _tag, _location}), do: nil
  defp preserve_shape({_type, _node, _tag, _location, value}), do: value
end
