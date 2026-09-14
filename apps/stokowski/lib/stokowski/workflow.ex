defmodule Stokowski.Workflow do
  @moduledoc """
  Parses Stokowski workflow files.

  Parsed YAML remains opaque so duplicate map keys stay visible to workflow
  validation.
  """

  @enforce_keys [:documents]
  defstruct [:documents]

  @opaque t :: %__MODULE__{documents: [term()]}

  @spec read(Path.t()) :: {:ok, t()} | {:error, Exception.t()}
  def read(path) do
    case YamlElixir.read_all_from_file(path, maps_as_keywords: true) do
      {:ok, documents} -> {:ok, %__MODULE__{documents: documents}}
      {:error, error} -> {:error, error}
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

  defp find_api_key_values(entries) when is_list(entries) do
    Enum.flat_map(entries, fn
      {"api_key", value} -> [value | find_api_key_values(value)]
      {_key, value} -> find_api_key_values(value)
      value -> find_api_key_values(value)
    end)
  end

  defp find_api_key_values(_value), do: []

  defp normalize_value(values) when is_list(values) do
    if Enum.all?(values, &match?({key, _value} when is_binary(key), &1)) do
      normalize_mapping(values)
    else
      normalize_sequence(values)
    end
  end

  defp normalize_value(value), do: {:ok, value}

  defp normalize_mapping(entries) do
    {merges, explicit} =
      Enum.split_with(entries, fn {key, _value} -> Regex.match?(~r/^<<\d*$/, key) end)

    with {:ok, inherited} <- normalize_merges(merges),
         {:ok, normalized} <- normalize_explicit(explicit) do
      {:ok, Map.merge(inherited, normalized)}
    end
  end

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
      if Map.has_key?(result, key) do
        {:halt, {:error, {:duplicate_key, key}}}
      else
        case normalize_value(value) do
          {:ok, normalized} -> {:cont, {:ok, Map.put(result, key, normalized)}}
          {:error, _reason} = error -> {:halt, error}
        end
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
end
