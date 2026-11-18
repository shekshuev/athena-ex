# AGENTS.md — Athena

Athena is a Phoenix learning platform built as a **modular monolith with bounded contexts**. **Boundary defines and checks module boundaries.** Keep business rules and data ownership inside their context; communicate through deliberate public APIs.

This file is the canonical entry point for all coding agents. Detailed instructions live in [.agents/](.agents/).

## Start here

Read [.agents/00-index.md](.agents/00-index.md), then the documents relevant to the task. Read [architecture.md](.agents/architecture.md) before changing domain ownership, module dependencies or public APIs.

| Task                                | Rules                                                                                |
| ----------------------------------- | ------------------------------------------------------------------------------------ |
| Architecture and context boundaries | [architecture.md](.agents/architecture.md)                                           |
| Elixir and OTP                      | [elixir.md](.agents/elixir.md)                                                       |
| Phoenix, CSS and JavaScript         | [phoenix.md](.agents/phoenix.md)                                                     |
| HEEx and forms                      | [html.md](.agents/html.md)                                                           |
| LiveViews, streams and hooks        | [liveview.md](.agents/liveview.md)                                                   |
| Ecto and migrations                 | [ecto.md](.agents/ecto.md), [data-and-migrations.md](.agents/data-and-migrations.md) |
| Permissions and privacy             | [security.md](.agents/security.md)                                                   |
| Domain invariants and events        | [domain.md](.agents/domain.md)                                                       |
| Tests and required checks           | [testing.md](.agents/testing.md), [quality.md](.agents/quality.md)                   |
| Local services and deployment       | [environment.md](.agents/environment.md)                                             |

## Non-negotiable rules

1. Preserve bounded-context ownership. Do not bypass Boundary or expand exports just to silence compiler warnings. Domain code must not depend on the web layer.
2. Use the included Req library for HTTP requests; do not introduce HTTPoison, Tesla or `:httpc`.
3. Enforce permissions and resource visibility on the server; preserve survey privacy and execution isolation.
4. Run `mix precommit` after completing changes. For module/dependency changes, also compile in dev to validate Boundary; it is disabled in test.
5. Preserve unrelated work. Do not commit or push unless requested, bypass checks, expose secrets or reset databases to fix tests.
6. Keep rules in English and update the relevant `.agents/` document when a convention changes.

`CLAUDE.md`, `.windsurfrules`, `.github/copilot-instructions.md` and `.cursor/rules/athena.mdc` are plain-text pointers to this file. Keep substantive rules in `.agents/`; do not duplicate them in agent-specific files or use symlinks.
