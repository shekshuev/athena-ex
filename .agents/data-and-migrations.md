---
title: Data ownership and migrations
applies_to:
  - "lib/athena/**"
  - "priv/repo/**"
read_when: "changing persistence, queries or migrations"
---

# Data and migrations

Read [ecto.md](ecto.md) and [architecture.md](architecture.md). Put queries and writes in the owning context. Use existing query scopes, preload associations required by templates, and avoid N+1 queries and unbounded UI lists.

Generate migrations with `mix ecto.gen.migration descriptive_name`. Add a new migration rather than editing an already applied one. Inspect neighboring migrations for types, prefixes, extensions and indexes. Consider existing rows, backfill cost, locks, constraints and rollback behavior. Verify up/down where safe on a local test database; never reset a database to make a migration pass.

Use transactions for related writes and preserve event/job behavior on failure. Caller-controlled params must not set ownership, authorization or other trusted fields. Use database constraints for invariants that must survive concurrent requests.
