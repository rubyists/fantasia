defmodule Stokowski.RunnerTrackingTest do
  use ExUnit.Case, async: true

  alias Stokowski.{Environment, Tracking}
  alias Stokowski.Runner.Codex

  @fixtures Path.expand("../fixtures", __DIR__)

  test "Codex argv makes permissions and ephemeral transport explicit" do
    assert {:ok, args} =
             Codex.argv("/tmp/work", "review", model: "test-model", reasoning_effort: "high")

    assert args == [
             "exec",
             "--sandbox",
             "danger-full-access",
             "--ephemeral",
             "--json",
             "--cd",
             "/tmp/work",
             "--config",
             ~s(approval_policy="never"),
             "--model",
             "test-model",
             "--config",
             ~s(model_reasoning_effort="high"),
             "review"
           ]

    assert {:error, {:unsupported_reasoning_effort, "extreme"}} =
             Codex.argv("/tmp/work", "review", reasoning_effort: "extreme")
  end

  test "Codex JSONL is normalized without treating arbitrary lines as final messages" do
    events =
      @fixtures
      |> Path.join("runners/codex-events.jsonl")
      |> File.stream!()
      |> Enum.map(fn line ->
        assert {:ok, event} = Codex.event(line)
        event
      end)

    assert Enum.at(events, 0).thread_id == "thread_fixture"
    assert Enum.at(events, 1).message == "fixture complete"

    assert Enum.at(events, 2).usage == %{
             "cached_input_tokens" => 2,
             "cache_write_input_tokens" => 0,
             "input_tokens" => 12,
             "output_tokens" => 7,
             "reasoning_output_tokens" => 3
           }

    assert {:ok, %{message: "fatal stream failure"}} =
             Codex.event(~s({"type":"error","message":"fatal stream failure"}))

    assert {:ok, %{message: "turn failure"}} =
             Codex.event(~s({"type":"turn.failed","error":{"message":"turn failure"}}))
  end

  test "latest tracking marker uses validated timestamps rather than response order" do
    assert {:ok, tracking_fixture} =
             YamlElixir.read_from_file(Path.join(@fixtures, "tracking/comments.yaml"))

    assert length(tracking_fixture["comments"]) == 3

    comments = Jason.decode!(File.read!(Path.join(@fixtures, "tracking/comments.json")))
    assert {:ok, latest} = Tracking.latest(comments, "state")
    assert latest.payload["state"] == "implement"
  end

  test "child environment excludes ambient secrets and overlays declared values" do
    parent = %{
      "PATH" => "/bin",
      "SSH_AUTH_SOCK" => "/tmp/agent.sock",
      "LINEAR_API_KEY" => "ambient-secret",
      "UNRELATED" => "drop"
    }

    declared = %{"LINEAR_API_KEY" => "$LINEAR_API_KEY", "PROJECT" => "fantasia"}

    assert Environment.child(parent, declared) == %{
             "PATH" => "/bin",
             "SSH_AUTH_SOCK" => "/tmp/agent.sock",
             "LINEAR_API_KEY" => "$LINEAR_API_KEY",
             "PROJECT" => "fantasia"
           }
  end
end
