defmodule Mix.Tasks.Phase1.Histories do
  @shortdoc "Regenerates the committed Phase 1 Continuum histories"

  @moduledoc """
  Regenerates the committed deterministic-core histories.

      mix phase1.histories --write

  This task is intentionally opt-in because the generated files are replay
  contracts and should only change alongside a reviewed flow or reducer change.
  """

  use Mix.Task

  alias Stokowski.Domain

  @impl Mix.Task
  def run(["--write"]) do
    {:ok, _applications} = Application.ensure_all_started(:continuum)

    Enum.each(fixtures(), fn {name, input} ->
      Continuum.Test.reset_in_memory!()

      {:ok, run_id} = Continuum.Test.start_synchronous(Stokowski.Flow, input)

      case Continuum.await(run_id, 1_000) do
        {:ok, %{state: :completed}} ->
          write_history!(run_id, Path.join(history_dir(), name <> ".term"))

        other ->
          Mix.raise("could not generate #{name} history: #{inspect(other)}")
      end
    end)

    Mix.shell().info("Generated #{length(fixtures())} Phase 1 histories")
  end

  def run([]) do
    Mix.shell().info(
      "History files are unchanged; use mix phase1.histories --write to regenerate"
    )
  end

  def run(_args), do: Mix.raise("mix phase1.histories accepts only --write")

  defp fixtures do
    [
      {"straight-through", %{snapshot: simple_snapshot(), events: [Domain.agent_completed()]}},
      {"approval",
       %{snapshot: review_snapshot(), events: [Domain.agent_completed(), Domain.approve()]}},
      {"rework",
       %{
         snapshot: review_snapshot(),
         events: [
           Domain.agent_completed(),
           Domain.rework("fix"),
           Domain.agent_completed(),
           Domain.approve()
         ]
       }},
      {"escalation",
       %{
         snapshot: review_snapshot(),
         events: [
           Domain.agent_completed(),
           Domain.rework("one"),
           Domain.agent_completed(),
           Domain.rework("two"),
           Domain.agent_completed(),
           Domain.rework("three")
         ]
       }},
      {"external-terminal", %{snapshot: review_snapshot(), events: [Domain.terminal(:external)]}},
      {"default-eight-phase", default_input()}
    ]
  end

  defp default_input do
    path = Path.join(repository_root(), "apps/stokowski/priv/examples/default/workflow.yaml")
    {:ok, snapshot} = Stokowski.Config.load(path)

    events = [
      Domain.agent_completed(),
      Domain.approve(),
      Domain.agent_completed(),
      Domain.approve(),
      Domain.agent_completed(),
      Domain.approve(),
      Domain.agent_completed()
    ]

    %{snapshot: snapshot, events: events}
  end

  defp simple_snapshot do
    %Domain.WorkflowSnapshot{
      workflow: "history",
      entry_phase: "work",
      graph: %{
        "work" => %Domain.Phase{
          name: "work",
          type: :agent,
          prompt: "work",
          transitions: %{"complete" => "done"}
        },
        "done" => %Domain.Phase{name: "done", type: :terminal}
      },
      prompts: %{},
      routing: %{},
      schema_version: 1,
      config_version: 1,
      fingerprint: "sha256:history"
    }
  end

  defp review_snapshot do
    %{
      simple_snapshot()
      | graph: %{
          "work" => %Domain.Phase{
            name: "work",
            type: :agent,
            prompt: "work",
            transitions: %{"complete" => "review"}
          },
          "review" => %Domain.Phase{
            name: "review",
            type: :gate,
            transitions: %{"approve" => "done"},
            rework_to: "work",
            max_rework: 2
          },
          "done" => %Domain.Phase{name: "done", type: :terminal}
        }
    }
  end

  defp repository_root, do: Path.expand("../../../../..", __DIR__)
  defp history_dir, do: Path.join(repository_root(), "apps/stokowski/test/fixtures/histories")

  defp write_history!(run_id, path) do
    generated = path <> ".generated"

    try do
      Continuum.Test.dump_history!(run_id, generated)

      if File.exists?(path) and
           Continuum.Test.load_history!(path) == Continuum.Test.load_history!(generated) do
        :ok
      else
        File.rename!(generated, path)
      end
    after
      File.rm(generated)
    end
  end
end
