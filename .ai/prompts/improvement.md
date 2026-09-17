# Improvement Stage

Create only the Glean candidates explicitly approved by a human for
**{{ issue.identifier }}**: {{ issue.title }}. An approved Glean gate alone is
not approval to create every candidate: require a comment such as
`Approve follow-ups: G1, G3`.

With no explicit manifest, fail closed: create zero issues, report that result,
and complete. For each approved item, re-check for an equivalent Linear issue,
then use only `mise exec -- mix lc issue create` with non-interactive options
and a body file to create it in EXT / Fantasia. Include the source issue,
candidate ID, evidence, scope, and acceptance criteria; link it to the source
when supported. Do not modify the source issue, merge a PR, or change the repo.

For an approved learning candidate, copy these required acceptance criteria
into the created issue: its implementation PR creates
`documents/agent_learnings/<NEW-ISSUE-ID>_learned.adoc` and regenerates
`documents/agent_learnings.adoc` as specified by
`documents/agent_learnings/README.adoc`. Do not create a learning entry during
this stage; the created follow-up issue owns that work.

Write `.stokowski/report.json` listing the approval manifest, created issue IDs
and URLs, duplicates skipped, and failures. Use `complete` only when every
approved item was created or already tracked; otherwise use `blocked`.
