defmodule Stokowski.Runner.Codex do
  @moduledoc """
  Phase 0 characterization of Codex argv and JSONL normalization.

  This module records provider-protocol evidence; it is not the production
  runner adapter or registry required by the pluggable-runner decision.
  """

  @efforts ~w(low medium high xhigh max)

  @spec argv(Path.t(), String.t(), keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def argv(workspace, prompt, opts \\ []) do
    effort = opts[:effort]
    session_id = opts[:session_id]

    if is_nil(effort) or effort in @efforts do
      args = if session_id, do: ["exec", "resume"], else: ["exec"]

      args = args ++ ["--dangerously-bypass-approvals-and-sandbox", "--json"]
      args = if session_id, do: args, else: args ++ ["--cd", workspace]

      args = if opts[:model], do: args ++ ["--model", opts[:model]], else: args

      args =
        if effort,
          do: args ++ ["--config", ~s(model_reasoning_effort="#{effort}")],
          else: args

      args = if session_id, do: args ++ [session_id], else: args

      {:ok, args ++ [prompt]}
    else
      {:error, {:unsupported_effort, effort}}
    end
  end

  @spec event(String.t()) :: {:ok, map()} | {:error, term()}
  def event(line) do
    with {:ok, event} when is_map(event) <- Jason.decode(line),
         type when is_binary(type) <- event["type"] do
      {:ok,
       %{
         type: type,
         thread_id: thread_id(event),
         message: message(event),
         usage: usage(event)
       }}
    else
      {:error, reason} -> {:error, {:invalid_json, reason}}
      _ -> {:error, :missing_event_type}
    end
  end

  defp thread_id(%{"type" => "thread.started", "thread_id" => id}), do: id
  defp thread_id(%{"type" => "thread.started", "thread" => %{"id" => id}}), do: id
  defp thread_id(_event), do: nil

  defp message(%{
         "type" => "item.completed",
         "item" => %{"type" => "agent_message", "text" => text}
       }),
       do: text

  defp message(%{"type" => "error", "message" => message}), do: message

  defp message(%{"type" => type, "error" => %{"message" => message}})
       when type in ["error", "turn.failed"],
       do: message

  defp message(_event), do: nil

  defp usage(%{"type" => "turn.completed", "usage" => usage}) when is_map(usage), do: usage
  defp usage(_event), do: nil
end
