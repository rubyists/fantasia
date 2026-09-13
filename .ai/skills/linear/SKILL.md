---
name: linear-cli
description: Create, update, organize, and comment on Linear CLI repository issues with mix lc, body files, assignment/status setup, and dependency links. Use for Linear work in this repository, not unrelated Linear projects.
---

# Linear CLI issues

Use this skill for Linear issue work in the `linear-cli` repository.

Use `mix lc` rather than raw `lc`, so the working tree's CLI is exercised.
If `mix lc` fails, report the failure; do not fall back to raw `lc`.

## Required client and body handling

- Interact with Linear only through `mix lc`. Do not use an MCP connector,
  browser, direct API request, or another CLI.
- Always use `--body-file PATH` for issue descriptions and comments: creation,
  description updates, and comments. The body file preserves text verbatim and
  avoids shell-quoting failures.
- Give every create, description-update, and comment operation a dedicated
  temporary body file. Write the final body to that file, pass it to `mix lc`,
  and remove it when the operation has finished or is abandoned.

## Issue creation

Before creating issues, establish the requested team, project, assignee,
status, labels, and direct dependency graph. Read existing issues only when
needed to avoid duplicates.

For each issue:

1. Write one independently implementable outcome with a concise title.
2. Put its goal, scope, preserved behavior, exclusions, acceptance criteria,
   and dependencies in the dedicated body file.
3. When labels were requested, append `--labels LABELS` to the create command.
4. Create it unassigned and non-interactively:

   ```sh
   mix lc issue create --yes --no-take \
     --team TEAM \
     --project PROJECT \
     --title TITLE \
     --body-file BODY_FILE
   ```

5. Capture the returned identifier. Do nothing further when neither an
   assignee nor a status was requested. Otherwise apply exactly what the user
   requested:

   * assignee and status:

     ```sh
     mix lc issue assign --assignee ASSIGNEE --status STATUS ISSUE_ID
     ```

   * assignee only:

     ```sh
     mix lc issue assign --assignee ASSIGNEE ISSUE_ID
     ```

   * status only:

     ```sh
     mix lc issue status ISSUE_ID --status STATUS
     ```

Do not commit while creating or organizing issues unless the user separately
asks for a commit.

## Issue updates

First read the issue when its current state matters, then make only the
requested change. Use `lc issue update` for supported issue fields and
lifecycle changes. For example, move an issue to a project:

```sh
mix lc issue update ISSUE_ID --project PROJECT
```

Or close an issue with a specific workflow status:

```sh
mix lc issue update ISSUE_ID --close --status "Done"
```

Do not use an update as an opportunity to change unrelated fields. Update a
description through its dedicated body file:

```sh
mix lc issue update ISSUE_ID --body-file BODY_FILE
```

## Comments

Use `lc issue comment` to add a comment with its dedicated body file. For
example:

```sh
mix lc issue comment ISSUE_ID --body-file COMMENT_FILE
```

Write comments that state the outcome, relevant evidence, and any remaining
blocker or handoff; do not repeat the issue description.

## Dependencies

Link a dependent issue to each direct prerequisite:

```sh
mix lc issue relation add DEPENDENT_ID PREREQUISITE_ID --type blocked-by
```

Use only direct edges; do not add relationships implied transitively. Verify
the finished graph with `mix lc issue relation list ISSUE_ID` for every
affected issue, then report the issue identifiers, assignment/status, direct
blockers, and independent work.

## Authorization

This skill standardizes mechanics only. It does not authorize creating,
editing, commenting on, assigning, or linking Linear issues; obtain the user's
request before performing each external change.
