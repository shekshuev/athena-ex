---
title: Quality checks and workflow
applies_to:
  - "**"
read_when: "finishing changes or modifying checks"
---

# Quality and workflow

Read task help before using an unfamiliar Mix task. Run focused checks during development and **run `mix precommit` when all changes are done**, fixing issues caused by the change.

The alias uses the test environment and runs `compile --warnings-as-errors`, `deps.unlock --unused`, `format`, then `test`. It can modify `mix.lock` and formatting; inspect the final diff and avoid unrelated changes. Test compilation does not run Boundary; validate module/dependency changes in dev as described in [architecture.md](architecture.md).

CI additionally checks format, Credo and Dialyzer and runs `mix test --exclude isolate`; inspect `.github/workflows/ci.yml` for current configuration. Do not claim skipped, failed or blocked checks passed. Distinguish existing failures from regressions using evidence.

Inspect the working tree before editing and preserve unrelated work. Do not commit or push unless requested. Do not bypass hooks or checks. Avoid dependency changes, generated files and broad formatting unless needed. Update rules in the same change when a convention changes.
