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

  defp find_api_key_values(entries) when is_list(entries) do
    Enum.flat_map(entries, fn
      {"api_key", value} -> [value | find_api_key_values(value)]
      {_key, value} -> find_api_key_values(value)
      value -> find_api_key_values(value)
    end)
  end

  defp find_api_key_values(_value), do: []
end
