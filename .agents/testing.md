---
title: Testing
applies_to:
  - "test/**"
read_when: "adding tests or diagnosing failures"
---

# Testing

Use `Athena.DataCase` for persistence and `AthenaWeb.ConnCase` for HTTP/LiveView tests; reuse `test/support/factory.ex`. Read testing sections in [elixir.md](elixir.md) and [liveview.md](liveview.md).

Use SQL Sandbox ownership provided by case modules. Do not enable asynchronous tests that mutate global configuration or share named processes without isolation. Start processes with `start_supervised!/1`; synchronize with monitors/messages or `:sys.get_state/1`, not sleeps.

Test observable outcomes, authorization failures and meaningful edge cases. Use DOM IDs and LiveViewTest selectors rather than raw HTML assertions. Keep tests deterministic with configured time zones and explicit timestamps where appropriate.

`config/test.exs` disables global background listeners because they cannot share each test's sandbox owner. Test listener handlers within sandbox ownership or explicitly arrange ownership for supervised processes. Oban uses manual testing mode; use helpers available through DataCase.

Run focused tests while iterating, then `mix precommit`. The test alias creates/migrates the test database, and `test/test_helper.exs` checks S3 storage. See [environment.md](environment.md) for service prerequisites. Report unavailable infrastructure accurately.
