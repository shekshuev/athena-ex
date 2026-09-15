# Athena LMS

Athena is a modular Learning Management System (LMS) built as a unified Elixir monolith.

> **Status: Active Development / Beta.** Athena is currently being used in real-world educational scenarios. While core features are stable and production-tested, internal APIs and schemas may evolve as we continue to scale.

## Features

- **Dynamic Course Builder:** Drag-and-drop syllabus editor with reusable library blocks, templates, and rich-text WYSIWYG editing powered by Tiptap.
- **Advanced Progression Engine:** Granular control over student paths with completion rules (button clicks, auto-grading gates) and time-based access locks (Waterline progression).
- **Interactive Quizzes & Exams:** Single/multiple choice, exact match (CTF flags), open essays with instructor review, and ticket-based slot exams.
- **Code Execution Sandbox:** Secure code runner for **Python** and **C++** backed by [isolate](https://github.com/ioi/isolate), plus **SQL (PostgreSQL)** via ephemeral restricted databases — with fine-grained time and memory limits, and hidden test cases.
- **SQL Challenges:** Ephemeral PostgreSQL sandboxes with query-result and state-verification evaluation modes.
- **Team & Cohort Management:** Shared team progress, isolated cohort schedules, competition mode with leaderboards, and strict Role-Based Access Control (RBAC) across Students, Instructors, and Admins.
- **Direct S3 Media Uploads:** Native, presigned URL integration with MinIO/AWS S3 for fast, secure file handling, user quotas, and background cleanup.
- **Content Sharing:** Share courses and library blocks between users with granular access controls.

## Tech Stack

### Core

- **Language:** Elixir 1.19+ (minimum `~> 1.15` in `mix.exs`)
- **Runtime:** Erlang/OTP 28+ (Docker images currently ship OTP 27; CI uses OTP 28)
- **Framework:** Phoenix 1.8+ with Bandit
- **Frontend:** Phoenix LiveView (SSR with real-time PubSub updates), Tiptap, CodeMirror 6
- **Database:** PostgreSQL 15+ with Ecto, `ltree` for section hierarchies
- **Background Jobs:** Oban (`code_execution`, `default`, `maintenance` queues)
- **Caching:** Cachex (account and draft caches)
- **Auth:** Custom session-based authentication with Argon2 hashing
- **Clustering:** libcluster (Gossip strategy for distributed runner nodes)
- **Architecture:** Boundary-enforced context modules, Flop for pagination
- **UI:** Tailwind CSS v4, daisyUI, Heroicons

## Getting Started

### Prerequisites

- Erlang/OTP 28+ and Elixir 1.19+ (see `.github/workflows/ci.yml` for exact CI versions)
- PostgreSQL 15+
- Node.js 20+ (required for `mix setup` and asset compilation)
- Docker (recommended for local infrastructure and code execution on macOS/Windows)

### Installation

#### Clone the repository

```bash
git clone https://github.com/shekshuev/athena-ex.git
cd athena-ex
```

#### Project Setup

We use Docker Compose to spin up local infrastructure (PostgreSQL, a dedicated SQL-runner Postgres, and MinIO) with zero configuration required.

```bash
# 1. Start the local databases and object storage
docker compose -f docker-compose.infra.yml up -d

# 2. Install dependencies, create DB, run migrations, set up MinIO buckets, and build assets
mix setup
```

`mix setup` runs `deps.get`, `ecto.setup`, `athena.storage.setup`, and the asset pipeline. **Seeds are empty** — you must create an admin user manually (see below).

If Postgres or MinIO run on a remote host, set `DEV_EXTERNAL_HOST` before starting the server.

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

Code challenges require a Linux environment with [isolate](https://github.com/ioi/isolate). **Native execution is not supported on macOS or Windows.**

On Linux, `iex -S mix phx.server` runs everything (web UI + all three language
runners) combined in one process — nothing to configure, this is the default
whenever the app isn't running from a built release.

For local development on macOS/Windows, run the web app locally and start
Linux runner container(s) for the language(s) you need:

```bash
# Terminal 1: web (after mix setup)
iex -S mix phx.server

# Terminal 2: isolated runner node(s) (Linux/Docker) — run one, several, or all:
docker compose -f docker-compose.dev-runner.yml up athena_runner_script
```

The dev runners use `RELEASE_COOKIE=dev_cookie_12345`. Ensure your web node uses the same cookie when clustering locally.

#### SQL Sandbox (Development)

SQL challenges create ephemeral databases on a dedicated Postgres instance. Local infra includes `postgres-runner` on port **5433** (`athena_runner` database).

By default, dev connects to the main Postgres on port 5432. For SQL tasks, point the runner at the dedicated instance:

```bash
export RUNNER_DATABASE_URL=ecto://postgres:postgres@localhost:5433/athena_runner
```

In production, configure `POSTGRES_RUNNER_PASSWORD` and port 5433 via `docker-compose.prod.yml` (`athena_runner_pg` service).

## Testing & Code Quality

We use ExUnit for testing, Credo for linting, and Dialyzer for static type checking.

```bash
# Run the test suite
mix test

# Run tests excluding isolate stress tests (same as CI)
mix test --exclude isolate

# Pre-commit checks (format + compile warnings + tests)
mix precommit

# Full pipeline (format, Credo, Dialyzer, tests, compile)
mix check
```

See `AGENTS.md` for project conventions and coding guidelines.

## CI/CD

The GitHub Actions pipeline (`.github/workflows/ci.yml`) handles:

- Code formatting checks (`mix format --check-formatted`)
- Compilation with warnings as errors
- Linting (Credo)
- Static type checking (Dialyzer)
- Unit and integration tests (`mix test --exclude isolate`)

Triggered on PRs and pushes to `main` and `develop`.

Docker images are built and pushed to GHCR on version tags (`v*`) via `.github/workflows/release.yml`. Each of the 4 variants is built, validated, and pushed **separately** on both `ubuntu-22.04` and `ubuntu-24.04` GitHub-hosted runners (real kernels, not just a base-image swap — isolate runs `--privileged` and shares the host kernel, so its cgroup v2/seccomp behavior isn't guaranteed portable across kernel versions). This produces two tags per variant, `-u22` and `-u24`; pick the one matching your deployment host's actual Ubuntu version:

- **Web/Core:** `ghcr.io/shekshuev/athena-ex-web:latest-u22` / `:latest-u24`
- **Runner (SQL, no isolate):** `ghcr.io/shekshuev/athena-ex-runner-db:latest-u22` / `:latest-u24`
- **Runner (compiled languages, isolate + g++):** `ghcr.io/shekshuev/athena-ex-runner-compiled:latest-u22` / `:latest-u24`
- **Runner (scripting languages, isolate + python3):** `ghcr.io/shekshuev/athena-ex-runner-script:latest-u22` / `:latest-u24`

A failed smoke test on one Ubuntu version only blocks that version's tag, not the other. Docker is the only supported deployment target — there is no standalone/bare-metal release artifact.

## Code Runner Note

> SQL challenges never touch isolate — they run in ephemeral, restricted Postgres roles/databases (see `Athena.Execution.SqlRunner`), so the `runner-db` image needs no special privileges.
>
> C++ and Python challenges rely on [isolate](https://github.com/ioi/isolate), which utilizes Linux kernel features (namespaces, rlimits, cgroups) to provide a secure sandbox for untrusted code execution. This is what the `runner-compiled` and `runner-script` images are for.
>
> **Inside Docker:** `isolate` uses Linux **cgroups v2** (`--cg`) for accurate memory tracking (RSS), CPU limits, and multi-threading/fork-bomb protection. The release entrypoint (`rel/overlays/bin/entrypoint`) initializes cgroup directories automatically for the `runner-compiled`/`runner-script` releases.
>
> Any container running `runner-compiled` or `runner-script` requires:
>
> - `privileged: true`
> - `pid: "host"`
> - `cgroup: host`
> - Volume mount: `/sys/fs/cgroup:/sys/fs/cgroup:rw`
>
> Because isolate runs `--privileged` and shares the host kernel, its behavior is validated on real `ubuntu-22.04`/`ubuntu-24.04` kernels in CI before every release (see CI/CD above) — not just built. A third tag, `-u20`, is also published for hosts still on Ubuntu 20.04, but GitHub retired hosted `ubuntu-20.04` Actions runners in 2025, so that tag is only glibc-matched (built from `debian:bullseye`, same glibc 2.31 as Ubuntu 20.04) — it is **not** validated against a real 20.04 kernel in CI. If you deploy it, run the `isolate --init --cg` / `isolate --run --cg` / `isolate --cleanup --cg` smoke test (see the CI workflow) on your actual host first.
>
> **On macOS/Windows:** Native execution is not supported — use `docker-compose.dev-runner.yml` or a Linux VM.

## Deployment

Athena is a set of separate Docker images clustered over **libcluster**
(Gossip) with a shared `RELEASE_COOKIE`. There is no all-in-one production
image and no operator-facing "role" setting — which image you run *is* the
role, baked in at build time via a dedicated Mix release per image. This is
enforced by construction, not by convention: a misconfigured or missing
setting can't silently boot the wrong thing.

### Images

Every image is published as three tags, `latest-u22`, `latest-u24`, and `latest-u20` (also versioned as `vX.Y.Z-u22`/`-u24`/`-u20`) — pick the one matching your host's actual Ubuntu version. `docker-compose.prod.yml` picks this via the `IMAGE_OS` variable in `.env` (`u22`, `u24`, or `u20`, defaults to `u24`). `u20` is glibc-matched, not kernel-validated in CI — see the isolate note above before using it in production.

| Image | Mix release | What it runs |
|-------|-------------|---------------|
| `ghcr.io/shekshuev/athena-ex-web` | `web` | LiveView UI, HTTP endpoints, Oban, background tasks. Unprivileged. |
| `ghcr.io/shekshuev/athena-ex-runner-db` | `runner_db` | SQL challenges (ephemeral Postgres roles/DBs, no isolate). Unprivileged. |
| `ghcr.io/shekshuev/athena-ex-runner-compiled` | `runner_compiled` | C++ challenges via isolate + g++. Requires `privileged: true`. |
| `ghcr.io/shekshuev/athena-ex-runner-script` | `runner_script` | Python challenges via isolate + python3. Requires `privileged: true`. |

Combined ("all-in-one") mode only exists when running from source without a
built release — i.e. local development (`iex -S mix phx.server`) and the test
suite. It cannot be reached in production; there's no release that produces it.

### Production Setup

1. Copy `.env.prod.example` to `.env` and fill in secure values (`SECRET_KEY_BASE`, `DATABASE_URL`, `RELEASE_COOKIE`, MinIO credentials, etc.).
2. Run `docker compose -f docker-compose.prod.yml up -d` (see [Compose Files](#compose-files) for other topologies).
3. Migrations run automatically on the web container's startup (via `bin/entrypoint` → `bin/migrate`).
4. Create the first admin:

```bash
docker exec athena_web /app/bin/web eval 'Athena.Release.create_admin("admin", "Admin123!")'
```

### Compose Files

| File | Use case |
|------|----------|
| `docker-compose.prod.yml` | Production: web + all 3 runner images + Postgres + dedicated SQL-runner Postgres + MinIO |
| `docker-compose.dev-runner.yml` | Local runner node(s) for development on macOS/Windows |
| `docker-compose.runner.yml` | Additional scalable runner instances (requires external `athena-network`) |
| `docker-compose.infra.yml` | Local dev infrastructure only |

Refer to these files for the authoritative service definitions rather than copying inline YAML snippets.

## Contributing

We welcome contributions! Please check out our open issues or submit a PR. For major architectural changes, please open an issue first to discuss.

Before submitting, run `mix check` or at minimum `mix precommit`.
