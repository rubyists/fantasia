defmodule Stokowski.PromptReportTrackingPhase1Test do
  use ExUnit.Case, async: true

  alias Stokowski.{Prompt, Report, Tracking}
  alias Stokowski.Domain

  test "prompt subset supports nested and flat context, conditionals, and lower" do
    issue = %Domain.Issue{
      id: "id",
      identifier: "EXT-1",
      title: "Title",
      description: "Details",
      labels: ["Bug", "Feature"]
    }

    template =
      "{{ issue.identifier }} / {{ issue_identifier }} / {{ issue.labels | lower }} {% if issue.description %}yes{% else %}no{% endif %} {{ issue.missing }}"

    rendered = Prompt.render(template, Prompt.context(issue))

    assert rendered =~ "EXT-1 / EXT-1 / bug, feature yes"
    refute rendered =~ "issue.missing"

    assert Prompt.render(
             "{% if issue.description %}yes{% else %}no{% endif %}",
             Prompt.context(%{identifier: "x"})
           ) == "no"
  end

  test "all vendored prompt examples render through the safe subset" do
    prompt_dir = Path.expand("../../../../vendor/stokowski/prompts", __DIR__)

    issue = %Domain.Issue{
      id: "id",
      identifier: "EXT-1",
      title: "Example issue",
      description: "Example description",
      state: "In Progress",
      url: "https://example.test/EXT-1",
      labels: ["bug"]
    }

    for path <- Path.wildcard(Path.join(prompt_dir, "*.example.md")) do
      rendered = Prompt.render(File.read!(path), Prompt.context(issue))
      assert rendered != ""
      refute rendered =~ "{{"
    end
  end

  test "assembled prompt order and lifecycle contract are deterministic" do
    {:ok, snapshot} =
      Stokowski.Config.load(Path.expand("../../priv/examples/default/workflow.yaml", __DIR__))

    issue = %Domain.Issue{id: "id", identifier: "EXT-1", title: "Title", description: "Details"}

    prompt =
      Prompt.assemble(snapshot, issue, "investigate",
        comments: [
          %{id: "2", body: "later", createdAt: "2026-01-02T00:00:00Z", author: "Ada"},
          %{id: "1", body: "earlier", createdAt: "2026-01-01T00:00:00Z", author: "Lin"}
        ]
      )

    assert prompt =~ "# Fantasia workflow"
    assert prompt =~ "EXT-1"
    assert prompt =~ "## Lifecycle Context"
    assert prompt =~ "### Structured reporting"
    assert :binary.match(prompt, "earlier") < :binary.match(prompt, "later")
  end

  test "report projection exposes unsupported evidence instead of hiding it" do
    assert {:ok, report} =
             Report.decode(
               ~s({"verdict":"needs-rework","claims":[{"claim":"A claim","confidence":"low"}]})
             )

    output = Report.render(report)
    assert output =~ "Needs rework"
    assert output =~ "A claim"
    assert output =~ "Findings"
  end

  test "tracking dual-read is stable and writers require data" do
    comments = [
      %{
        "id" => "a",
        "createdAt" => "2026-01-01T00:00:00Z",
        "body" => ~s(<!-- stokowski:state {"state":"old","timestamp":"2026-01-01T00:00:00Z"} -->)
      },
      %{
        "id" => "b",
        "createdAt" => "2026-01-01T00:00:00Z",
        "body" =>
          ~s(<!-- fantasia:v1:state {"schema":1,"state":"new","run":2,"timestamp":"2026-01-01T00:00:00Z"} -->)
      },
      %{
        "id" => "c",
        "createdAt" => "2026-01-02T00:00:00Z",
        "body" => "ordinary feedback",
        "user" => %{"displayName" => "Ada"}
      }
    ]

    assert {:ok, marker} = Tracking.latest(comments, "state")
    assert marker.payload["state"] == "new"
    assert {:error, :timestamp_required} = Tracking.write_state("new", nil, "effect-1")

    assert {:ok, body} =
             Tracking.write_gate("review", "waiting", "2026-01-03T00:00:00Z", "effect-2", run: 2)

    assert body =~ "fantasia:v1:gate"
    assert {:ok, gate} = Tracking.latest([%{"body" => body}], "gate")
    assert gate.payload["run"] == 2

    [feedback] = Tracking.recent_comments(comments, "2026-01-01T00:00:00Z")
    assert feedback.author == "Ada"
    assert feedback.body == "ordinary feedback"
  end
end
