---
title: Domain contracts and events
applies_to:
  - "lib/athena/**"
read_when: "changing domain behavior or cross-context events"
---

# Domain contracts

Read the relevant context facade and module documentation before changing behavior.

- Content owns authoring and search. Keep derived search data consistent through indexing workers and the backfill task, including deletions and changes to block text.
- Library question exports belong to Content. Reuse library read scopes and filters, validate course access before allowing its pinned bank to grant access, and recheck selected IDs at download time. Export only individual `quiz_question` blocks; report other selected types instead of silently ignoring them or expanding exams. Keep format limitations visible in the export UI and reject unsupported question content rather than losing it silently.
- Library question imports require `library.create` and create new private templates owned by the importing user; never trust file IDs, ownership or visibility. Skip unsupported or invalid individual questions and report their titles and reasons. Reject malformed files before creating records. Bound uploads and parser depth, disable XML DTDs/entities, do not intern uploaded names as atoms or fetch referenced resources, and convert rich text into supported TipTap nodes rather than storing raw HTML.
- Learning owns submissions, grading and progress. Gamification reacts to learning facts through `ActivityListener`; do not couple Learning mutations directly to XP writes. Preserve deduplication and idempotency when replaying jobs or events.
- Surveys are standalone questionnaires delivered through course survey blocks. They are not graded, award no XP and collect no engagement telemetry. Preserve branching, resume behavior and cohort privacy in results and exports.
- Execution runs untrusted code and SQL. Preserve isolate restrictions, time/memory/output limits, SQL restrictions, cleanup, family dispatch and verifier semantics. Do not relax controls to make a failing example pass.
- PubSub listeners, caches and Oban workers affect observable behavior. Trace producers and consumers before changing event shapes or topics. Keep workers safe to retry; do not broadcast success for failed writes.

Use [architecture.md](architecture.md) for ownership and [security.md](security.md) for visibility and privacy.

## Media upload settings

Keep general file extensions and per-file limits centralized in `Athena.Media.Config`: attachments, assignments and personal files share formats and a 2 GiB limit; videos use the same size limit with video extensions. Keep image/avatar and parser-based import limits specific to their purpose. Normalize missing browser MIME types in Media metadata validation before requiring the field.


## Multicode blocks

Content owns the shared prompt and a language-keyed map of ordinary code challenge
variants. SQL is excluded. A student language is available only when its reference
solution is nonblank and at least one test case passes the existing CodeChallenge
validation. Authoring may retain unfinished variants and empty test rows; these
must not become runnable student languages.

Keep the submitted language explicit and validate it against persisted content or
the exam question snapshot before execution. Reuse CodeChallenge, the existing
execution workers and Verifier; do not add a separate grading engine. Student
drafts preserve each language independently, and a delayed autosave must not
change the selected language. Never backfill or rewrite existing code blocks.
