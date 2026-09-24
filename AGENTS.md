# Fantasia repository instructions

Fantasia is an Elixir umbrella. Run repository commands from the umbrella root through the pinned
mise toolchain.

## Setup and verification

```shell
git submodule update --init --recursive
mise install
mise exec -- mix setup
mise exec -- mix format --check-formatted
mise exec -- mix test
mise exec -- mix do --app stokowski escript.build
./fantasia version
mise exec -- mix phase0.verify
```

Use `mise exec -- mix stokowski --dry-run` to validate and launch the vendored bootstrap workflow
without relying on ambient tool versions.

The Phase 0 package is an unsigned escript. CI builds and runs it outside the checkout on native
Linux x86_64 and macOS arm64 hosts; do not publish it as a release artifact.

`mix phase0.verify` validates the compatibility ledger, builds the `fantasia` escript, and executes
`fantasia version` from outside the checkout. Phase 0 contract code belongs in `apps/stokowski`;
repository-wide verification and launch tasks belong in `apps/repo_management`.

## Linear

Use `mise exec -- mix lc [LC_ARGS...]` for Linear operations. The task delegates to the checkout in
`vendor/linear-cli`, preserving its arguments, standard streams, and exit status.

Fantasia issues belong to the `EXT` team and the `Fantasia` project.

## Documents

Use the link:vendor/claude-plain-english-skill/skills/simple-english[`simple-english`] skill when
authoring technical documentation or instructions.

Use the link:vendor/claude-plain-english-skill/skills/plain-english[`plain-english`] skill when
authoring non-technical documentation, marketing copy, or other content intended for a general audience.

Do not apply both to the same text. Use `plain-english` for general audience content and `simple-english`
for technical content.

### Planning documents

- `documents/plans/pre-phase-1-plan.adoc` describes the vendored Python bootstrap.
- `documents/plans/initial-plan.adoc` describes the initial Elixir port and Fantasia release.

### Decision documents

- `documents/decisions/repository-management-mix-tasks-decision.adoc` records where repository-wide Mix tasks
  live and defines their discovery contract.
- `documents/decisions/0008-managed-toolchain-refresh.adoc` records the accepted mise dependency refresh
  and its version-scoped exception to ADR 0001's runner evidence update requirement.

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
