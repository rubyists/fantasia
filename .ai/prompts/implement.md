# Implementation Stage

You are implementing the solution for **{{ issue.identifier }}**: {{ issue.title }}

**Current status:** {{ issue.state }}
**Labels:** {{ issue.labels }}
**URL:** {{ issue.url }}

## Issue description

{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

## Objective

Implement the solution, create a PR, and ensure it passes all quality checks.

## Rule

Always sign git commits. If a gpg-agent is not available with a signing key,
stop and note that on the linear issue, do not create an unsigned commit.

Follow conventional commit message title rules for PR titles. This is
necessary for release-please to pick up our squash merge commits to main.

## First run

1. Read the investigation summary from the Linear comments.
2. Read the relevant source files identified in the investigation.
3. Create a feature branch from `main`:
   ```
   git checkout -b {{ issue.identifier | lower }}-<short-description>
   ```
4. Implement the changes with clean, logical commits.
5. Run the local quality gate (fast, no network required after deps are installed):
   - mix precommit
   For full CI-equivalent assurance before opening a PR (runs audits and
   validation that require network access), use `mix ci` instead.
6. Fix any failures before proceeding.
7. Push the branch and create a PR:
   ```
   git push -u origin HEAD
   gh pr create --title "<type>(scope): <concise title>" --body "<description>"
   ```
   We follow the same conventional commit message title for PR titles
8. Link the PR to the Linear issue.
9. Post a Linear comment with: what was done, what was tested, any known limitations.

## Rework run

If this is a rework run (a branch and PR already exist):

1. Find the existing PR:
   ```
   gh pr list --head <branch-name>
   ```
2. Read review comments and requested changes:
   ```
   gh pr view <number> --comments
   ```
3. Address each piece of feedback specifically.
4. Run the full quality suite again.
5. Push new commits to the existing branch (do not force-push).
6. Post a comment on the GitHub PR summarising the rework:
   - Which review comments were addressed
   - What was modified
   - Any decisions or trade-offs
7. Post a Linear comment summarising the rework.

## Quality bar

Before finishing, verify:

- [ ] All tests pass
- [ ] No type errors
- [ ] No lint errors
- [ ] All acceptance criteria from the ticket description met
- [ ] PR created (or updated) and linked to Linear issue
- [ ] Linear comment posted with a completion summary
