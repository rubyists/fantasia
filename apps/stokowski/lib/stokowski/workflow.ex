defmodule Stokowski.Workflow do
  @moduledoc """
  Parses Stokowski workflow files.

  Parsed YAML remains opaque so duplicate map keys and empty container types
  stay visible to workflow validation.
  """

  @enforce_keys [:documents]
  defstruct [:documents, unsupported_flow_mapping_aliases: []]

  @opaque t :: %__MODULE__{documents: [term()]}

  @spec read(Path.t()) :: {:ok, t()} | {:error, term()}
  def read(path) do
    with {:ok, yaml} <- File.read(path),
         {:ok, _documents} <- YamlElixir.read_all_from_string(yaml, maps_as_keywords: true),
         {:ok, documents} <- parse_documents(yaml) do
      unsupported_flow_mapping_aliases = find_flow_mapping_aliases(yaml)

      {:ok,
       %__MODULE__{
         documents: documents,
         unsupported_flow_mapping_aliases: unsupported_flow_mapping_aliases
       }}
    end
  end

  @spec api_key_values(t()) :: [term()]
  def api_key_values(%__MODULE__{documents: documents}) do
    find_api_key_values(documents)
  end

  @spec runner_values(t()) :: [String.t()]
  def runner_values(%__MODULE__{documents: documents}) do
    find_runner_values(documents)
  end

  @doc """
  Converts one parsed document to a deterministic string-keyed map.

  Duplicate keys and multi-document inputs are rejected before normalization,
  so callers never silently lose configuration while converting keyword maps.
  """
  @spec normalize(t()) ::
          {:ok, map()}
          | {:error,
             :empty_document
             | :multiple_documents
             | {:duplicate_key, binary()}
             | {:invalid_key, term()}
             | {:invalid_merge, :mapping_required | :flow_mapping_alias}}

  def normalize(%__MODULE__{
        documents: [document],
        unsupported_flow_mapping_aliases: unsupported_flow_mapping_aliases
      }) do
    case normalize_value(document) do
      {:ok, normalized} when unsupported_flow_mapping_aliases == [] ->
        {:ok, normalized}

      {:ok, _normalized} ->
        {:error, {:invalid_merge, :flow_mapping_alias}}

      {:error, {:duplicate_key, _key}} = error ->
        error

      {:error, _reason} when unsupported_flow_mapping_aliases != [] ->
        {:error, {:invalid_merge, :flow_mapping_alias}}

      {:error, _reason} = error ->
        error
    end
  end

  def normalize(%__MODULE__{documents: []}), do: {:error, :empty_document}
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

  defp find_runner_values({:mapping, entries}) do
    Enum.flat_map(entries, fn
      {"runner", value} when is_binary(value) -> [value | find_runner_values(value)]
      {_key, value} -> find_runner_values(value)
    end)
  end

  defp find_runner_values(entries) when is_list(entries),
    do: Enum.flat_map(entries, &find_runner_values/1)

  defp find_runner_values(_value), do: []

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
      case normalize_merge_value(value) do
        {:ok, normalized} ->
          # YAML merge sequences are ordered: an earlier mapping wins.
          {:cont, {:ok, Map.merge(normalized, result)}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  defp normalize_merge_value(value) do
    case normalize_value(value) do
      {:ok, normalized} when is_map(normalized) -> {:ok, normalized}
      {:ok, normalized} when is_list(normalized) -> normalize_merge_sequence(normalized)
      {:ok, _normalized} -> {:error, {:invalid_merge, :mapping_required}}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_merge_sequence(values) do
    Enum.reduce_while(values, {:ok, %{}}, fn value, {:ok, result} ->
      case value do
        normalized when is_map(normalized) ->
          # Keep keys from the first mapping when later mappings overlap.
          {:cont, {:ok, Map.merge(normalized, result)}}

        _value ->
          {:halt, {:error, {:invalid_merge, :mapping_required}}}
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

  defp parse_documents(yaml) do
    # YamlElixir is the public error guard; raw yamerl is required below to
    # retain duplicate keys and empty-container shape for normalization. Keep
    # the second parse protected so read/1 preserves its tuple contract if the
    # two parser passes ever disagree about an input.
    try do
      documents =
        yaml
        |> :yamerl_constr.string(
          detailed_constr: true,
          str_node_as_binary: true,
          keep_duplicate_keys: true
        )
        |> Enum.map(fn {:yamerl_doc, document} -> preserve_shape(document) end)

      {:ok, documents}
    rescue
      exception -> {:error, exception}
    catch
      kind, reason -> {:error, {kind, reason}}
    end
  end

  defp find_flow_mapping_aliases(yaml) do
    flow_anchors = Regex.scan(~r/&([A-Za-z0-9_-]+)\s*\{/, yaml, capture: :all_but_first)

    Enum.flat_map(flow_anchors, fn [name] ->
      alias = Regex.escape(name)

      if Regex.match?(~r/<<\s*:\s*(?:\*\s*#{alias}\b|\[[^\]]*\*\s*#{alias}\b)/s, yaml) do
        [name]
      else
        []
      end
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
