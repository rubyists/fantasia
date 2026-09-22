---
name: documents
description: >-
  Create or edit Fantasia repository documentation. Use for plans, decisions,
  architecture notes, runbooks, README files, and other project prose. Write
  AsciiDoc with the repository header, lowercase kebab-case filenames, native
  AsciiDoc markup, clean link attributes, and Mermaid diagrams.
---

# Fantasia documentation

Write repository documentation in AsciiDoc. Use the `.adoc` extension.

Use this skill when you create or edit project prose. This includes plans,
decisions, architecture notes, runbooks, and README files. Do not convert an
existing document unless the user asks for the conversion.

## File names

Use lowercase kebab-case file names. Use words that describe the document.

* Write `repository-management-decision.adoc`.
* Do not write `REPOSITORY_MANAGEMENT_DECISION.adoc`.
* Keep a required numeric prefix when an existing document series uses one,
  such as `0009-new-decision.adoc`.

## Document locations

Store authored documents under `documents/` at the repository root. Put each
document in the closest matching subdirectory.

* Store decisions in `documents/decisions/`.
* Store plans and implementation notes in `documents/plans/`.
* Store agent learning entries in `documents/agent_learnings/`.
* Keep only document indexes at `documents/` itself.

Do not add project documentation beside source files or at the repository root.
If no existing subdirectory fits, create a lowercase kebab-case subdirectory
under `documents/`.

## Start from the template

Copy `assets/document-template.adoc` when you create a document. Set
`my-title` and `revdate` before you write the body. Keep the author line and
the GitHub icon block.

Use the date format in the template: `Mon DD, YYYY`. For example,
`Sep 21, 2026`.

Add `:toc:` when the document has several sections or readers need to scan it.
Do not add a table of contents to a short note unless it helps navigation.

## Write native AsciiDoc

Use AsciiDoc markup. Do not use Markdown syntax inside `.adoc` files.

* Use `==` and `===` for sections.
* Use `*text*` for emphasis and backticks for code.
* Use AsciiDoc lists, tables, source blocks, admonitions, and cross references.
* Use `link:` for external links and `xref:` for document links.

Declare each reusable URL or document target as a document attribute near the
header. Use that attribute in the body. This keeps URLs and paths out of prose.

```adoc
:repository-management-decision: ../decisions/repository-management-mix-tasks-decision.adoc[the repository-management Mix task ownership decision]
:managed-toolchain-refresh-decision: ../decisions/0008-managed-toolchain-refresh.adoc[the managed toolchain refresh decision]

See xref:{repository-management-decision}. Also see
xref:{managed-toolchain-refresh-decision}.
```

The paths above apply to a document in `documents/plans/`. Make document paths
relative to the document that contains them.

Do not create an attribute for a link that appears once and reads better as a
normal cross reference. Keep attribute names short, specific, and lowercase.

## Diagrams

Use Mermaid for diagrams. Put Mermaid source in an AsciiDoc source block.
Describe the diagram in nearby prose or provide an equivalent table when the
diagram carries important information.

```adoc
[source,mermaid]
----
flowchart LR
    Source --> Build --> Release
----
```

## Before you finish

Make sure that every created or materially edited document has the template
header. Check these items:

* The file uses `.adoc` and a lowercase kebab-case name.
* The header includes the title, author, `revdate`, `:icons: font`,
  `:env-github:`, and the GitHub caption block.
* The body uses AsciiDoc syntax, not Markdown syntax.
* Reused links are document attributes.
* Each diagram uses Mermaid in a `[source,mermaid]` block.
* The document describes the current state. Put history in a decision record,
  implementation note, or changelog when it matters.

## References

* `assets/document-template.adoc` is the required header template.
* `assets/example-ash-domain-erd.adoc` shows a Mermaid diagram and accessible
  text alternatives.
* `assets/decisions/decision.adoc` records document location and format.
* `assets/decisions/related-decision.adoc` records link and diagram rules.
