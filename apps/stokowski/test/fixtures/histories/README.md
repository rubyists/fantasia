# Continuum history fixtures

These `.term` files are committed replay evidence, generated with the pinned
toolchain by `mix phase1.histories --write`. The task builds each input from
the same provider-neutral values used by the flow tests and writes the
in-memory Continuum journal with `Continuum.Test.dump_history!/3`.

The fixtures and their exact event sequences are:

| Fixture | Snapshot | Events |
| --- | --- | --- |
| `straight-through` | two-phase `history` workflow | `complete` |
| `approval` | `history` workflow with `work -> review -> done`, `max_rework: 2` | `complete`, `approve` |
| `rework` | same `history` workflow | `complete`, `rework("fix")`, `complete`, `approve` |
| `escalation` | same `history` workflow | `complete`, `rework("one")`, `complete`, `rework("two")`, `complete`, `rework("three")` |
| `external-terminal` | same `history` workflow | `terminal(:external)` |
| `default-eight-phase` | `priv/examples/default/workflow.yaml` | `complete`, `approve`, `complete`, `approve`, `complete`, `approve`, `complete` |

The generator is intentionally opt-in because changing a fixture changes the
replay contract. Review the binary diff and the reducer/flow tests after
running it.
