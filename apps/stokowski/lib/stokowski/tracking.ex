defmodule Stokowski.Tracking do
  @moduledoc "Deterministic dual-read tracking codec with Fantasia v1 writers."

  @marker ~r/<!--\s*(?<namespace>stokowski:|fantasia:v1:)(?<kind>state|gate)\s+(?<json>\{.*?\})\s*-->/s
  @machine_marker ~r/<!--\s*(?:stokowski:|fantasia:v1:)/

  @doc "Return the newest valid marker of a requested kind."
  @spec latest([map()], String.t()) :: {:ok, map()} | :none
  def latest(comments, kind) when kind in [:state, :gate],
    do: latest(comments, Atom.to_string(kind))

  def latest(comments, kind) when kind in ["state", "gate"] do
    comments
    |> valid_markers()
    |> Enum.filter(&(&1.kind == kind))
    |> Enum.max_by(&sort_key/1, fn -> nil end)
    |> case do
      nil -> :none
      marker -> {:ok, marker}
    end
  end

  @doc "Decode every valid legacy or Fantasia v1 marker in stable order."
  @spec markers([map()] | binary()) :: [map()]
  def markers(body) when is_binary(body), do: decode_body(body)
  def markers(comments) when is_list(comments), do: valid_markers(comments)

  @doc "Return the newest valid marker across state and gate entries."
  def latest_marker(comments),
    do: valid_markers(comments) |> Enum.max_by(&sort_key/1, fn -> nil end)

  @doc "Compatibility projection used by the tracker recovery boundary."
  def parse_latest_tracking(comments) do
    case latest_marker(comments) do
      nil -> nil
      %{kind: kind, payload: payload} -> Map.put(payload, "type", kind)
    end
  end

  @doc "Return the timestamp embedded in the newest valid tracking marker."
  @spec latest_timestamp([map()]) :: DateTime.t() | nil
  def latest_timestamp(comments) do
    case latest_marker(comments) do
      nil -> nil
      marker -> marker.timestamp
    end
  end

  @doc "Compatibility helper returning the timestamp as an ISO string."
  def get_last_tracking_timestamp(comments) do
    case latest_timestamp(comments) do
      nil -> nil
      timestamp -> DateTime.to_iso8601(timestamp)
    end
  end

  @doc "Return attributed, non-machine comments after a tracking timestamp."
  def recent_comments(comments, timestamp \\ nil, opts \\ []) do
    cutoff = parse_timestamp(timestamp)
    limit = Keyword.get(opts, :limit, :infinity)

    comments
    |> Enum.reject(&machine_comment?/1)
    |> Enum.map(&normalize_comment/1)
    |> Enum.filter(fn comment -> after_cutoff?(comment.created_at, cutoff) end)
    |> Enum.sort_by(&{timestamp_key(&1.created_at), &1.id, &1.body})
    |> take_limit(limit)
  end

  @doc "Legacy-compatible alias for recent comment projection."
  def comments_since(comments, timestamp), do: recent_comments(comments, timestamp)

  @doc "Phase 0-compatible name for the recent attributed comment projection."
  def get_comments_since(comments, timestamp), do: recent_comments(comments, timestamp)

  @doc "Encode a Fantasia v1 state marker using caller-supplied time and identity."
  def write_state(state, timestamp, effect_id, opts \\ []) do
    with {:ok, timestamp} <- normalize_timestamp(timestamp),
         :ok <- valid_text(state, :state),
         :ok <- valid_text(effect_id, :effect_id),
         :ok <- valid_run(Keyword.get(opts, :run, 1)) do
      payload = %{
        "schema" => 1,
        "state" => to_string(state),
        "run" => Keyword.get(opts, :run, 1),
        "timestamp" => timestamp,
        "effect_id" => to_string(effect_id)
      }

      payload =
        if Keyword.has_key?(opts, :workflow),
          do: Map.put(payload, "workflow", Keyword.get(opts, :workflow)),
          else: payload

      {:ok, encode_marker("state", payload)}
    end
  end

  @doc "Encode a Fantasia v1 gate marker using caller-supplied time and identity."
  def write_gate(state, status, timestamp, effect_id, opts \\ []) do
    with {:ok, timestamp} <- normalize_timestamp(timestamp),
         :ok <- valid_text(state, :state),
         :ok <- valid_gate_status(status),
         :ok <- valid_text(effect_id, :effect_id),
         :ok <- valid_run(Keyword.get(opts, :run, 1)) do
      payload = %{
        "schema" => 1,
        "state" => to_string(state),
        "status" => to_string(status),
        "run" => Keyword.get(opts, :run, 1),
        "timestamp" => timestamp,
        "effect_id" => to_string(effect_id)
      }

      payload =
        if Keyword.has_key?(opts, :rework_to),
          do: Map.put(payload, "rework_to", Keyword.get(opts, :rework_to)),
          else: payload

      {:ok, encode_marker("gate", payload)}
    end
  end

  @doc "Convenient state writer; unlike the Phase 0 writer it never reads a clock."
  def state_comment(state, timestamp, effect_id, opts \\ []),
    do: write_state(state, timestamp, effect_id, opts)

  @doc "Convenient gate writer; unlike the Phase 0 writer it never reads a clock."
  def gate_comment(state, status, timestamp, effect_id, opts \\ []),
    do: write_gate(state, status, timestamp, effect_id, opts)

  @doc "Encode a marker payload when the caller already built the structured data."
  def encode(kind, payload) when kind in [:state, :gate, "state", "gate"] and is_map(payload) do
    kind = to_string(kind)
    {:ok, encode_marker(kind, Map.put_new(payload, "schema", 1))}
  end

  # These names make migration call sites explicit and are intentionally pure.
  def make_state_comment(state, opts) when is_list(opts) do
    write_state(state, Keyword.get(opts, :timestamp), Keyword.get(opts, :effect_id), opts)
  end

  def make_gate_comment(state, status, opts) when is_list(opts) do
    write_gate(state, status, Keyword.get(opts, :timestamp), Keyword.get(opts, :effect_id), opts)
  end

  def make_state_comment(_state, _run, _workflow), do: {:error, :timestamp_required}

  defp valid_markers(comments) do
    comments
    |> stable_comments()
    |> Enum.flat_map(fn {comment, comment_order} ->
      comment
      |> body_of()
      |> decode_body()
      |> Enum.with_index()
      |> Enum.map(fn {marker, marker_order} ->
        %{marker | order: {comment_order, marker_order}}
      end)
    end)
  end

  defp stable_comments(comments) do
    comments
    |> Enum.map(&normalize_comment/1)
    |> Enum.sort_by(fn comment ->
      {timestamp_key(comment.created_at), comment.id, comment.body}
    end)
    |> Enum.with_index()
  end

  defp decode_body(body) do
    Regex.scan(@marker, body, capture: :all_names)
    |> Enum.with_index()
    |> Enum.flat_map(fn {[json, kind, namespace], index} ->
      namespace = String.trim_trailing(namespace, ":")

      with {:ok, payload} <- Jason.decode(json),
           {:ok, timestamp} <- embedded_timestamp(payload),
           :ok <- validate_payload(payload, kind, namespace) do
        [
          %{
            kind: kind,
            namespace: namespace,
            payload: normalize_payload(payload),
            timestamp: timestamp,
            order: {0, index}
          }
        ]
      else
        _ -> []
      end
    end)
  end

  defp embedded_timestamp(%{"timestamp" => timestamp}) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, parsed, _offset} -> {:ok, parsed}
      _ -> {:error, :invalid_timestamp}
    end
  end

  defp embedded_timestamp(_), do: {:error, :missing_timestamp}

  defp validate_payload(payload, kind, namespace) do
    schema_ok =
      case {namespace, Map.get(payload, "schema")} do
        {"fantasia:v1", 1} -> true
        # Early Phase 1 markers were emitted before the schema field was
        # required. Keep reading them while all new writes remain versioned.
        {"fantasia:v1", nil} -> true
        {"fantasia:v1", _} -> false
        {"stokowski", _} -> true
        _ -> false
      end

    required =
      case kind do
        "state" ->
          is_binary(Map.get(payload, "state")) and Map.get(payload, "state") != ""

        "gate" ->
          is_binary(Map.get(payload, "state")) and Map.get(payload, "state") != "" and
            valid_gate_payload_status?(Map.get(payload, "status"), namespace)

        _ ->
          false
      end

    if schema_ok and required, do: :ok, else: {:error, :invalid_payload}
  end

  defp normalize_payload(payload) do
    payload
    |> Map.put_new("run", 1)
    |> Map.put_new("schema", 1)
  end

  defp sort_key(%{timestamp: timestamp, order: order}),
    do: {DateTime.to_unix(timestamp, :microsecond), order}

  defp body_of(%{body: body}) when is_binary(body), do: body
  defp body_of(%{"body" => body}) when is_binary(body), do: body
  defp body_of(_), do: ""

  defp normalize_comment(comment) do
    %{
      id: to_string(Map.get(comment, :id, Map.get(comment, "id", ""))),
      body: body_of(comment),
      created_at:
        parse_timestamp(
          Map.get(
            comment,
            :created_at,
            Map.get(
              comment,
              :createdAt,
              Map.get(comment, "createdAt", Map.get(comment, "created_at"))
            )
          )
        ),
      author: author(comment)
    }
  end

  defp author(comment) do
    actor =
      Map.get(comment, :user, Map.get(comment, "user")) ||
        Map.get(comment, :botActor, Map.get(comment, "botActor")) ||
        Map.get(comment, :externalUser, Map.get(comment, "externalUser"))

    cond do
      is_map(actor) ->
        to_string(
          Map.get(
            actor,
            "displayName",
            Map.get(
              actor,
              :displayName,
              Map.get(actor, "name", Map.get(actor, :name, "unknown author"))
            )
          )
        )

      is_binary(actor) and actor != "" ->
        actor

      true ->
        "unknown author"
    end
  end

  defp machine_comment?(comment),
    do: Regex.match?(@machine_marker, body_of(comment))

  defp valid_gate_payload_status?(status, "stokowski"),
    do: is_binary(status) and status != ""

  defp valid_gate_payload_status?(status, "fantasia:v1"),
    do: status in ~w(waiting approved rework escalated)

  defp valid_gate_payload_status?(_status, _namespace), do: false

  defp after_cutoff?(_created_at, nil), do: true
  defp after_cutoff?(nil, _cutoff), do: false
  defp after_cutoff?(created_at, cutoff), do: DateTime.compare(created_at, cutoff) == :gt

  defp timestamp_key(nil), do: -1
  defp timestamp_key(timestamp), do: DateTime.to_unix(timestamp, :microsecond)

  defp parse_timestamp(nil), do: nil
  defp parse_timestamp(%DateTime{} = timestamp), do: timestamp

  defp parse_timestamp(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, value, _} -> value
      _ -> nil
    end
  end

  defp parse_timestamp(_), do: nil

  defp normalize_timestamp(%DateTime{} = timestamp), do: {:ok, DateTime.to_iso8601(timestamp)}

  defp normalize_timestamp(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, _value, _} -> {:ok, timestamp}
      _ -> {:error, :invalid_timestamp}
    end
  end

  defp normalize_timestamp(nil), do: {:error, :timestamp_required}
  defp normalize_timestamp(_), do: {:error, :invalid_timestamp}

  defp valid_text(value, _field) when is_binary(value) and value != "", do: :ok
  defp valid_text(_value, field), do: {:error, {field, :required}}

  defp valid_gate_status(status)
       when status in [:waiting, :approved, :rework, :escalated],
       do: :ok

  defp valid_gate_status(status)
       when is_binary(status) and status in ~w(waiting approved rework escalated),
       do: :ok

  defp valid_gate_status(_status), do: {:error, {:status, :invalid}}

  defp valid_run(run) when is_integer(run) and run > 0, do: :ok
  defp valid_run(_run), do: {:error, {:run, :invalid}}

  defp encode_marker(kind, payload), do: "<!-- fantasia:v1:#{kind} #{Jason.encode!(payload)} -->"

  defp take_limit(values, :infinity), do: values

  defp take_limit(values, limit) when is_integer(limit) and limit >= 0,
    do: Enum.take(values, limit)

  defp take_limit(values, _), do: values
end
