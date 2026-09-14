# Fantasia repository instructions

Fantasia is an Elixir umbrella. Run repository commands from the umbrella root through the pinned
mise toolchain.

## Setup and verification

```shell
mise install
mise exec -- mix setup
mise exec -- mix format --check-formatted
mise exec -- mix test
```

Use `mise exec -- mix stokowski --dry-run` to validate and launch the vendored bootstrap workflow
without relying on ambient tool versions.

## Linear

Use `mise exec -- mix lc [LC_ARGS...]` for Linear operations. The task delegates to the checkout in
`vendor/linear-cli`, preserving its arguments, standard streams, and exit status.

Fantasia issues belong to the `EXT` team and the `Fantasia` project.

## Planning documents

- `documents/pre-phase-1-plan.adoc` describes the vendored Python bootstrap.
- `documents/initial-plan.adoc` describes the initial Elixir port and Fantasia release.
- `documents/repository-management-mix-tasks-decision.adoc` records where repository-wide Mix tasks
  live and defines their discovery contract.

When a later decision changes a plan, add a new decision document or an implementation note rather
than rewriting completed history without explanation.

## Vendored repositories

Every entry under `vendor/` is a Git submodule. Read its local instructions before changing it.
Changes to vendored source must be committed in the repository that owns the submodule, followed by
an intentional gitlink update here. Do not leave an unexplained dirty or detached submodule.

Use `mise exec -- mix submodules.update` to fast-forward clean submodules to the `main` or `master`
branch declared in `.gitmodules` while keeping each checkout on its tracking branch.

Keep secrets out of tracked workflow files and command output. `workflow.yaml` may omit
`tracker.api_key` or reference an environment variable such as `$LINEAR_API_KEY`; it must never
contain a literal API key.
