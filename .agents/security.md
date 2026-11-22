---
title: Authorization and privacy
applies_to:
  - "lib/athena/identity/**"
  - "lib/athena_web/**"
  - "lib/athena/surveys/**"
read_when: "changing access, user input, downloads or result visibility"
---

# Authorization and privacy

Use `Athena.Identity.can?/3`, `can_any?/2`, `scope_query/3` and the owning context's policies as appropriate. Enforce authorization on the server for reads and writes, including event handlers, exports and downloads. A hidden button or authenticated session alone does not grant resource access.

Follow `AthenaWeb.Router` live sessions and `AthenaWeb.Hooks.Auth`; Athena currently assigns `current_user`. The generic Phoenix guidance about `current_scope` applies if scope-based authentication is introduced; it does not request renaming the current model. Preserve account/role reloads and forced password-change behavior.

Keep cohort membership, instructor access, sharing and ownership checks in scoped context operations. Never trust a client-supplied account or cohort ID as proof of access. Test denied access and access to another user's resource as well as success.

Manual completion goes through `Learning.complete_button_gate/4`, which resolves current course/lesson access and permits only visible button gates. Keep `mark_completed/3` for trusted completion facts from submissions and internal progression. Exam creation/resume goes through the authorized `Learning.get_or_create_exam_attempt/7` facade; it derives team and exam settings from persisted data. Preview exceptions require an active persisted test-run session for the ephemeral account and course, never a client flag. Profile ownership is assigned on the struct at creation and is not a castable form field.

Library access is centralized in `Athena.Content.LibraryAccess`. Reading through a pinned template requires an accessible, non-deleted course and `library.read`. Inherited editing additionally requires `library.update`, course write access and matching template/course ownership. Inheritance never grants deletion, resharing, publication or ownership changes; those require direct template permissions. Reevaluate grants on mutations and invalidate open library views when course shares or pins change. Pin only readable templates. Course-specific copies are private, owned by the course owner and pinned in one transaction so all course editors can collaborate without changing third-party originals.

Survey cohort results and exports conceal respondent identity; individual enrollment results follow the existing visibility policy. Preserve the ban on survey engagement telemetry, grading and XP. Do not leak identities through logs, analytics or result fields.

Do not print secrets, commit credentials or log sensitive payloads. Use runtime configuration for deployment secrets.
