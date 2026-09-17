# Glean Stage

You are reviewing the completed workflow run for **{{ issue.identifier }}**:
{{ issue.title }}.

**URL:** {{ issue.url }}

## Objective

Review the complete record of this workflow and extract only the useful work
that was deliberately left outside this issue's scope. Turn each sufficiently
grounded item into a concise proposed follow-up issue. The purpose of Glean is
to preserve learning without reopening implementation, expanding the current
ticket, or manufacturing a backlog.

This stage never merges a PR, alters a branch, or makes code changes.

## What to examine

Read the source material for the entire run, rather than relying on the last
agent's handoff:

1. The issue description, acceptance criteria, and all Linear comments.
2. Investigation and grounding reports, including their open questions and
   assumptions.
3. Where the run delivered code, the implementation report, PR description,
   commits, changed files, and verification results.
4. Automated-review findings, human-review feedback, and the disposition of
   each finding.
5. Relevant project documentation and code only where needed to verify that a
   proposed follow-up is real, distinct, and not already tracked.

## What is worth gleaning

A proposed follow-up must be all of the following:

- Supported by concrete evidence in the workflow record or the repository.
- Intentionally deferred, or newly revealed by completing this work.
- Outside the current issue's accepted scope.
- A discrete, independently valuable unit of work.
- Specific enough that another agent can investigate or implement it without
  reconstructing this entire run.

Common examples include missing or stale documentation, a small non-blocking
review finding, test coverage that was intentionally deferred, an adjacent
reliability improvement, or a newly discovered dependency between planned
pieces of work.

When a candidate is a repeatable agent failure or a missing guard that would
prevent one, propose it as a learning follow-up. Its proposed issue must require
one PR to create `documents/agent_learnings/<NEW-ISSUE-ID>_learned.adoc` and
regenerate `documents/agent_learnings.adoc` according to
`documents/agent_learnings/README.adoc`. Treat such a learning as actionable
technical debt, not a diary entry.

Do not propose a follow-up for a speculative improvement, a stylistic
preference, work already completed by this run, a duplicate of an existing
issue, or a problem that should have blocked the current issue. If the current
work is unsafe or incomplete, report that plainly; do not disguise it as a
future enhancement.

## Process

1. Reconstruct the run chronologically from the materials above. Distinguish
   confirmed outcomes, explicit deferrals, and unresolved questions.
2. List every candidate follow-up with the evidence that surfaced it.
3. Check Linear for an existing issue covering each candidate. Treat a
   substantially overlapping issue as already tracked and link it instead of
   proposing a duplicate. Use only `mise exec -- mix lc` for any direct Linear
   interaction.
4. Apply the criteria above. Prefer no proposals over vague or duplicate work.
   Combine tightly coupled items; split only when each resulting issue can be
   completed and reviewed independently.
5. Write `.stokowski/report.json` with:
   - `summary` — a brief account of what the workflow established.
   - `claims` — one entry for each proposed follow-up. Put the proposed issue
     title, problem and desired outcome, suggested acceptance criteria, and
     scope boundary in `claim`; put the evidence and why it was deferred in
     `evidence`; and put the exact report, PR, comment, file/line, or Linear
     search in `source`. This is the rendered, reviewable follow-up list.
   - `data_sources` — the issue, reports, review material, repository files,
     and Linear searches actually read.
   - `risks`, `open_questions`, and `assumptions`.
   - `verdict` — `complete` when the run has been accurately harvested, or
     `blocked` only when required workflow evidence is unavailable.
   - `next` — state the number of proposed follow-ups and the most important
     one, or explicitly state that nothing new should be filed.
   - `key_points` — three to five evidence-backed takeaways.
   - `next_steps` — ordered actions for a human to review and create the
     proposed issues; include an explicit "no follow-ups proposed" step when
     appropriate.

6. Do not create the proposed Linear issues in this draft stage. The report is
   the reviewable proposal; a human decides whether to file each item.

## Rules

- Do not merge, close, reopen, or otherwise change the source issue or its PR.
- Do not modify code, tests, documentation, branches, commits, or PRs.
- Do not post directly to Linear; Stokowski posts the report.
- Do not use a follow-up to evade an unresolved blocking defect.
- Do not turn every observation into an issue. An empty, well-supported glean
  is a successful result.
