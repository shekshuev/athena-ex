---
title: Architecture and bounded contexts
applies_to:
  - "lib/**"
  - "mix.exs"
read_when: "changing domain behavior, dependencies, public APIs or module ownership"
---

# Architecture

**Athena is a modular monolith organized into bounded contexts. Boundary defines and checks module boundaries.** A shared OTP application and database do not make context internals a shared API.

## Context ownership

| Context                | Responsibility                                                     |
| ---------------------- | ------------------------------------------------------------------ |
| `Athena.Identity`      | Accounts, profiles, roles, authentication and permissions          |
| `Athena.Content`       | Courses, sections, blocks, reusable library, authoring and search  |
| `Athena.Learning`      | Cohorts, enrollments, submissions, progress, grading and test runs |
| `Athena.Execution`     | Dispatching and verifying code and SQL execution                   |
| `Athena.Surveys`       | Questionnaire authoring, branching, responses, results and exports |
| `Athena.Media`         | Files, sharing, quotas and object storage                          |
| `Athena.Gamification`  | XP, badges, streaks, leagues, sprints and challenges               |
| `Athena.Messaging`     | Conversations, participants, messages and mentions                 |
| `Athena.Engagement`    | Learning telemetry, rollups, statistics and proctoring             |
| `Athena.Announcements` | Authored announcements and audience visibility                     |

`Athena.Audit`, `Athena.Tracing`, `Athena.TimeZones`, `Athena.Repo` and infrastructure workers support these contexts. `AthenaWeb` owns HTTP, LiveView, channels and presentation, not business rules.

## Boundary is an architectural contract

Current declarations are in [Athena](../lib/athena.ex), [AthenaWeb](../lib/athena_web.ex) and [Mix.Tasks.Athena](../lib/mix/tasks/athena.ex). `Athena` declares `deps: []` and explicit exports; `AthenaWeb` and the Mix task boundary depend on `Athena`. The domain contexts above are logical bounded contexts inside the `Athena` boundary; they do not currently each declare `use Boundary`.

- Use context facade functions for cross-context operations. Keep schemas, queries, policies and mutations with their owning context. Do not add direct writes to another context's tables or reach into implementation modules for convenience.
- Keep business decisions out of LiveViews, controllers and hooks. Existing exported schemas and `Repo` are a compatibility surface, not a reason to put new domain queries in the web layer.
- Domain code must remain independent of `AthenaWeb`. Existing application startup exceptions are infrastructure wiring, not a pattern for domain dependencies.
- Add exports or dependencies only for deliberate public contracts. Do not silence warnings with ignore attributes, dynamic calls or broader exports to bypass a boundary. Existing exceptions do not authorize new ones.
- Preserve facade side effects: authorization, audit, PubSub notifications, cache invalidation and job scheduling. Calling an internal mutator directly can silently skip them.
- Use soft IDs and public APIs across contexts. Do not add database foreign keys or cascading deletes between bounded contexts; real foreign keys belong inside the owning context. Validate cross-context references through the owning context's public API. Existing cross-context associations are legacy, not a precedent for new hard links; do not rewrite them in unrelated work.
- For a new context or a changed dependency direction, explain ownership and the contract. Agree architectural changes with the user when intent is unclear.

Boundary runs outside the test environment: `mix.exs` omits its compiler for `:test`. **Passing `mix precommit` alone does not validate boundaries.** Run `MIX_ENV=dev mix compile --warnings-as-errors` for module or dependency changes; ensure affected modules are recompiled (use `--force` when validating declaration changes).

## Runtime roles

This is one Mix application with `web`, `runner_db`, `runner_compiled` and `runner_script` releases. `config/runtime.exs` derives roles from the release name; `Athena.Application` selects children for `default`, `runner` or `all`. Separate execution nodes do not turn domain contexts into independent microservices. Preserve runner isolation and family dispatch.
