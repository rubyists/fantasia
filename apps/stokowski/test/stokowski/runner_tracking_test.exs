defmodule Stokowski.RunnerTrackingTest do
  use ExUnit.Case, async: true

  alias Stokowski.{Environment, Tracking}
  alias Stokowski.Runner.Codex

  @fixtures Path.expand("../fixtures", __DIR__)

  test "Codex fresh argv uses unified effort and unrestricted execution explicitly" do
    fixture = yaml_fixture("runners/codex.yaml")
    effort = List.last(fixture["valid_effort"])

    assert {:ok, args} =
             Codex.argv("/tmp/work", "review", model: "test-model", effort: effort)

    assert fixture["stdin"] == "closed"
    assert fixture["workflow_key"] == "effort"
    assert substitute(fixture["fresh_argv"]) == ["codex" | args]

    assert {:error, {:unsupported_effort, "extreme"}} =
             Codex.argv("/tmp/work", "review", effort: "extreme")
  end

  test "Codex resume argv carries the opaque native session reference" do
    fixture = yaml_fixture("runners/codex.yaml")

    assert {:ok, args} =
             Codex.argv("/tmp/work", "implement",
               model: "test-model",
               effort: "max",
               session_id: "thread-fixture"
             )

    assert fixture["session"]["native_resume_with_reference"]
    assert substitute(fixture["resume_argv"], "implement") == ["codex" | args]
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
    tracking_fixture = yaml_fixture("tracking/comments.yaml")

    comments =
      Enum.map(tracking_fixture["comments"], fn comment ->
        %{"body" => comment["body"], "createdAt" => comment["created_at"]}
      end)

    assert {:ok, latest} = Tracking.latest(comments, "state")
    assert latest.payload["state"] == "review"
    assert {:ok, legacy} = Tracking.latest(Enum.take(comments, 1), "state")
    assert legacy.payload["state"] == "implement"
    assert {:ok, gate} = Tracking.latest(comments, "gate")
    assert gate.payload["status"] == "waiting"
  end

  test "tracking ignores markers without a valid embedded timestamp" do
    comments = [
      %{
        "createdAt" => "2026-09-14T06:00:00Z",
        "body" => ~s(<!-- stokowski:state {"state":"missing"} -->)
      },
      %{
        "createdAt" => "2026-09-14T06:01:00Z",
        "body" => ~s(<!-- stokowski:state {"state":"invalid","timestamp":"not-a-time"} -->)
      },
      %{
        "createdAt" => "2026-09-14T05:00:00Z",
        "body" =>
          ~s(<!-- stokowski:state {"state":"valid","timestamp":"2026-09-14T05:00:00Z"} -->)
      }
    ]

    assert {:ok, latest} = Tracking.latest(comments, "state")
    assert latest.payload["state"] == "valid"
  end

  test "child environment excludes ambient secrets and overlays declared values" do
    fixture = yaml_fixture("runners/environment.yaml")
    inherit = fixture["inherit"]
    project_allowlist = fixture["project_allowlist"]

    assert MapSet.new(inherit) == MapSet.new(Environment.default_allowlist())
    assert MapSet.new(project_allowlist) == MapSet.new(Environment.project_allowlist())

    parent =
      Map.new(inherit, &{&1, "inherited"})
      |> Map.merge(%{
        "PATH" => "/bin",
        "SSH_AUTH_SOCK" => "/tmp/agent.sock",
        "LINEAR_API_KEY" => "ambient-secret",
        "UNRELATED" => "drop"
      })

    declared =
      Map.new(project_allowlist, &{&1, "declared"})
      |> Map.put("PROJECT", "fantasia")

    expected =
      Map.take(parent, inherit)
      |> Map.merge(Map.new(project_allowlist, &{&1, "declared"}))

    assert Environment.child(parent, declared) == expected
    assert fixture["declared_overrides_inherited"]
    assert fixture["ambient_secrets"] == "redact"
  end

  defp yaml_fixture(name),
    do: YamlElixir.read_from_file(Path.join(@fixtures, name)) |> elem(1)

  defp substitute(values, prompt \\ "review") do
    replacements = %{
      "WORKSPACE" => "/tmp/work",
      "PROMPT" => prompt,
      "SESSION_ID" => "thread-fixture",
      "MODEL" => "test-model"
    }

    Enum.map(values, &Map.get(replacements, &1, &1))
  end
end
