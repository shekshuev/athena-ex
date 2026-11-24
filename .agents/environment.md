---
title: Environment and runtime roles
applies_to:
  - "config/**"
  - "rel/**"
  - "Dockerfile*"
  - "docker-compose*.yml"
read_when: "running locally or changing configuration, infrastructure or releases"
---

# Environment

Use `.tool-versions`, `mix.exs` and CI as sources for tool versions. Read `README.md` and the relevant compose file before starting services. Use existing dependencies; HTTP clients should use Req.

Tests require PostgreSQL and S3-compatible storage. `config/test.exs` uses `DEV_EXTERNAL_HOST` (default `localhost`), a partition-specific `athena_test` database and `athena-test-*` bucket. Local storage defaults target MinIO; CI provisions Garage and injects credentials. Execution tests may also need a runner database and isolate tooling. Missing services do not justify weakening tests.

Inspect `config/runtime.exs` and `Athena.Application` for release-role wiring. Preserve separation of web and execution nodes and existing environment variable conventions. Document new deployment settings in `.env.prod.example` with placeholders. Avoid destructive setup/reset tasks on existing data.

For MinIO behind TLS termination, configure `MINIO_SCHEME` for the internal endpoint and `MINIO_PUBLIC_SCHEME` / `MINIO_PUBLIC_PORT` for the browser endpoint. `MINIO_PORT_EXTERNAL` is the Docker port mapping. See [storage deployment](../docs/deployment/storage-https.md).

`mix athena.storage.setup` creates private buckets and removes bucket policies; there is no public prefix. For existing production storage, audit saved links first and use the backed-up, explicit hardening operation described in [private storage deployment](../docs/deployment/private-storage.md). Run administrative policy changes with storage-admin credentials separately from the running application's scoped service identity. Do not execute them through database migrations.

ClickHouse sandbox table-engine permissions are configured with `allowed_table_engines` under `Athena.Execution.Database.ClickHouse` in `config/config.exs`. Keep the engine policy in configuration, grant only explicit engine names, and preserve the independent bans on external sources and administrative operations. Restart the runner after configuration-file changes; new sandbox users receive the configured grants.

Production deployment uses self-contained service definitions in `docker-compose.prod.yml`. `docker-compose.sql-services.yml` is shared by development and extra-runner configurations only. Copy `docker/clickhouse/execution.xml` with its relative path when transferring production configuration.
