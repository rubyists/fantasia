defmodule Stokowski.Runner.Codex do
  @moduledoc "Pure Codex argv and JSONL normalization contract."

  @reasoning ~w(minimal low medium high xhigh)

  @spec argv(Path.t(), String.t(), keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def argv(workspace, prompt, opts \\ []) do
    reasoning = opts[:reasoning_effort]

    if is_nil(reasoning) or reasoning in @reasoning do
      args = [
        "exec",
        "--sandbox",
        "danger-full-access",
        "--ephemeral",
        "--json",
        "--cd",
        workspace,
        "--config",
        ~s(approval_policy="never")
      ]

      args = if opts[:model], do: args ++ ["--model", opts[:model]], else: args

      args =
        if reasoning,
          do: args ++ ["--config", ~s(model_reasoning_effort="#{reasoning}")],
          else: args

      {:ok, args ++ [prompt]}
    else
      {:error, {:unsupported_reasoning_effort, reasoning}}
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

  defp message(%{"type" => type, "error" => %{"message" => message}})
       when type in ["error", "turn.failed"],
       do: message

  defp message(_event), do: nil

  defp usage(%{"type" => "turn.completed", "usage" => usage}) when is_map(usage), do: usage
  defp usage(_event), do: nil
end
