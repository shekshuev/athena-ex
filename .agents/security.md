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

Survey cohort results and exports conceal respondent identity; individual enrollment results follow the existing visibility policy. Preserve the ban on survey engagement telemetry, grading and XP. Do not leak identities through logs, analytics or result fields.

Do not print secrets, commit credentials or log sensitive payloads. Use runtime configuration for deployment secrets.
