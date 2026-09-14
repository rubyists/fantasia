defmodule Stokowski.Tracking do
  @moduledoc "Timestamp-ordered compatibility parsing for Stokowski tracking markers."

  @marker ~r/<!--\s*(?:stokowski:|fantasia:v1:)(?<kind>state|gate)\s+(?<json>\{.*?\})\s*-->/s

  @spec latest([map()], String.t()) :: {:ok, map()} | :none
  def latest(comments, kind) when kind in ["state", "gate"] do
    comments
    |> Enum.flat_map(&markers(&1, kind))
    |> Enum.max_by(& &1.timestamp, DateTime, fn -> nil end)
    |> case do
      nil -> :none
      marker -> {:ok, marker}
    end
  end

  defp markers(comment, kind) do
    created_at = comment["createdAt"] || comment[:created_at]
    body = comment["body"] || comment[:body] || ""

    Regex.scan(@marker, body, capture: :all_names)
    |> Enum.flat_map(fn [json, found_kind] ->
      with true <- found_kind == kind,
           {:ok, payload} <- Jason.decode(json),
           timestamp when is_binary(timestamp) <- payload["timestamp"] || created_at,
           {:ok, parsed, _offset} <- DateTime.from_iso8601(timestamp) do
        [%{kind: found_kind, payload: payload, timestamp: parsed}]
      else
        _ -> []
      end
    end)
  end
end
