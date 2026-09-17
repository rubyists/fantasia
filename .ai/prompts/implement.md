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

## First run

1. Read the investigation summary from the Linear comments.
2. Read the relevant source files identified in the investigation.
3. Create a feature branch from `main`:
   ```
   git checkout -b {{ issue.identifier | lower }}-<short-description>
   ```
4. Implement the changes with clean, logical commits.
5. Run the full quality suite:
   - Type checking
   - Linting
   - All tests
6. Fix any failures before proceeding.
7. Review your own diff, and wait for the github review action to complete.
   Once the review is posted, investigate any issues and address them
   before continuing. Comment on the PR with which were actioned, which
   were not, and why.
8. Push the branch and create a PR:
   ```
   git push -u origin HEAD
   gh pr create --title "{{ issue.identifier }}: <concise title>" --body "<description>"
   ```
9. Link the PR to the Linear issue.
10. Write `.stokowski/report.json`: what changed and why, the exact
    verification commands and their real results, assumptions, and known
    limitations. Set `verdict` to `complete` or `blocked`, put the reviewer's
    summary in `next`, and anything they must check in `next_steps`. Add 3-5
    bullets to `key_points`: what changed, what you actually verified, and
    anything the reviewer should be suspicious of. Those four fields render at
    the top of the Linear comment and are what the gate reads first — someone
    who reads only them should know whether this is safe to merge. Stokowski
    posts it.

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
7. Write a fresh `.stokowski/report.json` covering the rework.

## Quality bar

Before finishing, verify:

- [ ] All tests pass
- [ ] No type errors
- [ ] No lint errors (rubocop)
- [ ] All acceptance criteria from the ticket description met
- [ ] PR created (or updated) and linked to Linear issue
- [ ] PR Review comments addressed (actioned or skipped, with justification)
- [ ] Evidence captured to `$STOKOWSKI_ARTIFACTS` for any visible change
- [ ] `.stokowski/report.json` written, every claim sourced
