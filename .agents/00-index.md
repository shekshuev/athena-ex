---
title: Instruction routing
applies_to:
  - "**"
read_when: "starting a task after reading AGENTS.md"
---

# Instruction routing

Read architecture first for domain or dependency changes, then the documents relevant to the task. Usually two or three documents are enough; read additional ones when the task crosses concerns.

| Paths or topic                                         | Read                                                                 |
| ------------------------------------------------------ | -------------------------------------------------------------------- |
| Domain ownership, dependencies, public APIs, `mix.exs` | [architecture.md](architecture.md)                                   |
| `lib/**/*.ex`, OTP processes                           | [elixir.md](elixir.md)                                               |
| `lib/athena_web/**`, `assets/**`                       | [phoenix.md](phoenix.md)                                             |
| HEEx, components, forms                                | [html.md](html.md)                                                   |
| LiveViews, streams, hooks, LiveView tests              | [liveview.md](liveview.md)                                           |
| Schemas, queries, `priv/repo/**`                       | [ecto.md](ecto.md), [data-and-migrations.md](data-and-migrations.md) |
| Authentication, permissions, privacy                   | [security.md](security.md)                                           |
| Domain invariants, events, execution                   | [domain.md](domain.md)                                               |
| `test/**`, verification, CI                            | [testing.md](testing.md), [quality.md](quality.md)                   |
| `config/**`, releases, Docker, local services          | [environment.md](environment.md)                                     |

Each document has `applies_to` path hints and a `read_when` description. These are routing metadata, not an automatic loading mechanism. Update the relevant document when changing a convention.
