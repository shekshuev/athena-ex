# Development and Deployment

Technical setup, architecture, testing, and deployment reference for Athena. For a product overview, see the [README](../README.md).

## Architecture

Each bounded context owns its business rules and data operations. Cross-context operations should use context facades; the web layer handles presentation and delegates domain behavior.

| Context         | Responsibility                                                  |
| --------------- | --------------------------------------------------------------- |
| `Identity`      | Accounts, profiles, roles, authentication, permissions          |
| `Content`       | Courses, sections, blocks, library, sharing, search             |
| `Learning`      | Cohorts, enrollments, submissions, progress, grading, test runs |
| `Execution`     | Code and SQL execution, runner dispatch, verification           |
| `Surveys`       | Questionnaire authoring, branching, responses, results, exports |
| `Media`         | Files, quotas, sharing, object storage                          |
| `Gamification`  | XP, badges, streaks, leagues, sprints, challenges               |
| `Messaging`     | Conversations, participants, messages, mentions                 |
| `Engagement`    | Telemetry, rollups, analytics, proctoring signals               |
| `Announcements` | Announcements and audience visibility                           |

The current Boundary declarations expose selected modules from [`Athena`](../lib/athena.ex) to [`AthenaWeb`](../lib/athena_web.ex) and the Mix task boundary. Individual domain contexts are logical boundaries inside `Athena`; they do not each declare a separate Boundary yet. See [architecture rules](../.agents/architecture.md) for ownership and dependency conventions.

The web and execution releases share one codebase and OTP application. Separate runner nodes isolate execution workloads; they do not make the domain contexts independent microservices.

## Tech Stack

- **Language:** Elixir 1.19+ (minimum `~> 1.15` in `mix.exs`)
- **Runtime:** Erlang/OTP 27 locally and in Docker; OTP 28 in CI (exact versions below)
- **Framework:** Phoenix 1.8+ with Bandit
- **Frontend:** Phoenix LiveView (SSR with real-time PubSub updates), Tiptap, CodeMirror 6
- **Database:** PostgreSQL 15+ with Ecto, `ltree` for section hierarchies
- **Background Jobs:** Oban (`code_execution`, `default`, `maintenance`, `search_index` queues)
- **Caching:** Cachex for accounts and drafts, plus dedicated engagement dashboard and learning leaderboard caches
- **Auth:** Custom session-based authentication with Argon2 hashing
- **Clustering:** libcluster (Gossip strategy for distributed runner nodes)
- **Architecture:** Modular monolith with Boundary checks
- **Pagination:** Flop
- **UI:** Tailwind CSS v4, daisyUI, Heroicons

## Local Development

### Prerequisites

- Elixir and Erlang/OTP matching the target environment (see the table below)
- PostgreSQL 15+
- Node.js 20+ (required for `mix setup` and asset compilation)
- Docker (recommended for local infrastructure and code execution on macOS/Windows)

The repository currently pins different OTP versions for local development, images, and CI:

| Environment       | Elixir                | Erlang/OTP | Source                                     |
| ----------------- | --------------------- | ---------- | ------------------------------------------ |
| Local development | 1.19.5 (OTP 27 build) | 27.3.4     | [`.tool-versions`](../.tool-versions)      |
| Docker builds     | 1.19.5                | 27.3.4.10  | `Dockerfile.*` build defaults              |
| CI                | 1.19.5 (OTP 28 build) | 28.3.1     | [CI workflow](../.github/workflows/ci.yml) |

### Installation

#### Clone the repository

```bash
git clone https://github.com/shekshuev/athena-ex.git
cd athena-ex
```

#### Project Setup

We use Docker Compose to spin up local infrastructure (PostgreSQL, a dedicated SQL-runner Postgres, and MinIO).

```bash
# 1. Start the local databases and object storage
docker compose -f docker-compose.infra.yml up -d

# 2. Install dependencies, create DB, run migrations, set up MinIO buckets, and build assets
mix setup
```

`mix setup` runs `deps.get`, `ecto.setup`, `athena.storage.setup`, and the asset pipeline. **Seeds are empty** – you must create an admin user manually (see below).

If Postgres or MinIO run on a remote host, set `DEV_EXTERNAL_HOST` before running `mix setup` and starting the server.

#### Start the Server

```bash
iex -S mix phx.server
```

The application will be available at `http://localhost:4000`. MinIO console is available at `http://localhost:9001` (credentials: `minioadmin` / `minioadmin`).

#### Create the First Admin

After `mix setup`, create an admin in IEx:

```elixir
Athena.Release.create_admin("admin", "Admin123!")
```

Alternatively, step by step:

```elixir
alias Athena.Identity.{Roles, Accounts, Role}

{:ok, %Role{id: role_id}} =
  Roles.system_create_role(%{"name" => "admin", "permissions" => ["admin"]})

{:ok, _account} =
  Accounts.create_account(%{"login" => "admin", "password" => "Admin123!", "role_id" => role_id})
```

### Local Code Execution

Python and C++ execution requires Linux with [isolate](https://github.com/ioi/isolate), the language toolchain, and the sandbox facilities described under [Execution containers](#execution-containers). SQL uses a dedicated PostgreSQL instance and does not require isolate.

Running `iex -S mix phx.server` from source starts the web application and registers local execution workers for all three language families. Python/C++ execution still requires the Linux prerequisites; those workers cannot execute isolate workloads natively on macOS or Windows.

[`docker-compose.dev-runner.yml`](../docker-compose.dev-runner.yml) provides Linux runner containers. For example, this builds and starts the Python runner:

```bash
docker compose -f docker-compose.dev-runner.yml up athena_runner_script
```

**This command alone does not connect a host development server to the runner.** Plain `iex -S mix phx.server` starts an unnamed node, and the source application's combined `all` mode does not configure Gossip discovery. Connecting external runners requires a named distributed web node, a matching Erlang cookie, reachable node addresses, and explicit discovery or connection setup. The dev Compose file uses host networking and `127.0.0.1` node addresses, so host-to-container connectivity must also be checked for the Docker platform in use.

The dev runner cookie is `dev_cookie_12345`; a matching cookie alone is insufficient. There is currently no verified end-to-end macOS/Windows host-to-runner quickstart. The [production topology](#deployment) runs web and runner releases together; a Linux VM is another option for developing with local isolate execution.

#### SQL Sandbox (Development)

SQL challenges create ephemeral databases on a dedicated Postgres instance. Local infra includes `postgres-runner` on port **5433** (`athena_runner` database).

By default, dev connects to the main Postgres on port 5432. For SQL tasks, point the runner at the dedicated instance:

```bash
export RUNNER_DATABASE_URL=ecto://postgres:postgres@localhost:5433/athena_runner
```

In production, configure `POSTGRES_RUNNER_PASSWORD` and port 5433 via `docker-compose.prod.yml` (`athena_runner_pg` service).

## Testing & Code Quality

We use ExUnit for testing, Credo for linting, and Dialyzer for static type checking.

Start PostgreSQL and S3-compatible storage before running tests. The test alias creates and migrates the test database; the test helper checks the storage bucket. Local tests use MinIO, while CI provisions Garage. See [`config/test.exs`](../config/test.exs) for database, bucket, and `DEV_EXTERNAL_HOST` settings. SQL tests may also require a runner database. Tests tagged `:isolate` require the Linux sandbox and toolchains.

```bash
# Run the test suite
mix test

# Exclude all tests tagged :isolate (same as CI)
mix test --exclude isolate

# Required pre-commit checks (includes isolate tests)
mix precommit

# Full pipeline (format, Credo, Dialyzer, tests, compile)
mix check
```

`mix precommit` runs compilation with warnings as errors, unlocks unused dependencies, formats code, and runs the full test suite. `mix check` adds Credo and Dialyzer and excludes `:isolate` tests.

**Boundary is disabled in the test environment**, including `mix precommit`, `mix check`, and the current CI compilation step. After changing modules or dependencies, also run:

```bash
MIX_ENV=dev mix compile --warnings-as-errors
```

Use `--force` when changing Boundary declarations to ensure affected modules are checked. See [AGENTS.md](../AGENTS.md) and the [instruction index](../.agents/00-index.md) for project conventions.

## CI/CD

The GitHub Actions pipeline (`.github/workflows/ci.yml`) handles:

- Code formatting checks (`mix format --check-formatted`)
- Compilation with warnings as errors
- Linting (Credo)
- Static type checking (Dialyzer)
- Unit and integration tests (`mix test --exclude isolate`)

Triggered on PRs and pushes to `main` and `develop`.

Docker images are built and pushed to GHCR on version tags (`v*`) via the [release workflow](../.github/workflows/release.yml). Each image variant is built and validated separately on `ubuntu-22.04` and `ubuntu-24.04`. Python/C++ variants receive a privileged isolate smoke test on the runner's real kernel before publication. A failed smoke test blocks that matrix entry's push; other entries continue independently.

See [Images](#images) for the four releases and tag conventions. Docker is the supported deployment target; the workflow does not publish a standalone bare-metal release artifact.

## Deployment

For file uploads through HTTPS nginx, see [MinIO and nginx configuration](deployment/storage-https.md).

Athena is a set of separate Docker images clustered over **libcluster**
(Gossip) with a shared `RELEASE_COOKIE`. There is no all-in-one production
image and no operator-facing "role" setting – which image you run _is_ the
role, baked in at build time via a dedicated Mix release per image. This is
enforced by construction, not by convention: a misconfigured or missing
setting can't silently boot the wrong thing.

### Images

Every image is published as two tags, `latest-u22` and `latest-u24` (also versioned as `vX.Y.Z-u22`/`-u24`) – pick the one matching your host's actual Ubuntu version. `docker-compose.prod.yml` picks this via the `IMAGE_OS` variable in `.env` (`u22` or `u24`, defaults to `u24`).

| Image                                         | Mix release       | What it runs                                                             |
| --------------------------------------------- | ----------------- | ------------------------------------------------------------------------ |
| `ghcr.io/shekshuev/athena-ex-web`             | `web`             | LiveView UI, HTTP endpoints, Oban, background tasks. Unprivileged.       |
| `ghcr.io/shekshuev/athena-ex-runner-db`       | `runner_db`       | SQL challenges (ephemeral Postgres roles/DBs, no isolate). Unprivileged. |
| `ghcr.io/shekshuev/athena-ex-runner-compiled` | `runner_compiled` | C++ challenges via isolate + g++. Requires `privileged: true`.           |
| `ghcr.io/shekshuev/athena-ex-runner-script`   | `runner_script`   | Python challenges via isolate + python3. Requires `privileged: true`.    |

Combined ("all-in-one") mode only exists when running from source without a
built release – i.e. local development (`iex -S mix phx.server`) and the test
suite. It cannot be reached in production; there's no release that produces it.

### Execution Containers

SQL challenges use ephemeral restricted PostgreSQL roles and databases through `Athena.Execution.SqlRunner`; `runner-db` needs no isolate privileges. Production Compose supplies a dedicated PostgreSQL instance on port 5433, configured with `POSTGRES_RUNNER_PASSWORD`.

Python and C++ use isolate with Linux namespaces, resource limits, and cgroups v2 (`--cg`). The [release entrypoint](../rel/overlays/bin/entrypoint) prepares cgroup directories for `runner_compiled` and `runner_script`. Containers need the privileges and writable cgroup access required by that setup.

The dev runner Compose file explicitly sets `privileged: true`, host PID and cgroup namespaces, and a writable `/sys/fs/cgroup` mount. **Production Compose currently sets `privileged: true` but omits those explicit namespace and mount settings.** The files therefore differ; validate cgroup initialization and sandbox execution on the target host before relying on the production topology. The release smoke test validates the workflow's container configuration, not every Compose topology.

### Production Setup

1. Copy `.env.prod.example` to `.env` and fill in secure values (`SECRET_KEY_BASE`, `DATABASE_URL`, `RELEASE_COOKIE`, MinIO credentials, etc.).
2. Run `docker compose -f docker-compose.prod.yml up -d` (see [Compose Files](#compose-files) for other topologies).
3. Migrations run automatically on the web container's startup (via `bin/entrypoint` → `bin/migrate`).
4. Create the first admin:

```bash
docker exec athena_web /app/bin/web eval 'Athena.Release.create_admin("admin", "Admin123!")'
```

### Compose Files

| File                            | Use case                                                                                                                                    |
| ------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| `docker-compose.prod.yml`       | Production: web + all 3 runner images + Postgres + dedicated SQL-runner Postgres + MinIO                                                    |
| `docker-compose.dev-runner.yml` | Linux runner containers for development; host-node connection requires additional setup (see [Local Code Execution](#local-code-execution)) |
| `docker-compose.runner.yml`     | Additional scalable runner instances (requires external `athena-network`)                                                                   |
| `docker-compose.infra.yml`      | Local dev infrastructure only                                                                                                               |

Refer to these files for the authoritative service definitions rather than copying inline YAML snippets.
