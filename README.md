# Athena LMS

Athena is a modular Learning Management System (LMS) built as a unified Elixir monolith.

> **Status: Active Development / Beta.** Athena is currently being used in real-world educational scenarios. While core features are stable and production-tested, internal APIs and schemas may evolve as we continue to scale.

## Features

- **Dynamic Course Builder:** Drag-and-drop syllabus editor with reusable library blocks, templates, and rich-text WYSIWYG editing powered by Tiptap.
- **Advanced Progression Engine:** Granular control over student paths with completion rules (button clicks, auto-grading gates) and time-based access locks (Waterline progression).
- **Interactive Quizzes & Exams:** Single/multiple choice, exact match (CTF flags), open essays with instructor review, and ticket-based slot exams.
- **Code Execution Sandbox:** Secure code runner backed by [isolate](https://github.com/ioi/isolate) for **Python**, **C++**, and **SQL (PostgreSQL)** with fine-grained time and memory limits, and hidden test cases.
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

For local development on macOS/Windows, run the web app locally and start a runner container:

```bash
# Terminal 1: web (after mix setup)
iex -S mix phx.server

# Terminal 2: isolated runner node (Linux/Docker)
docker compose -f docker-compose.dev-runner.yml up
```

The dev runner uses `RELEASE_COOKIE=dev_cookie_12345`. Ensure your web node uses the same cookie when clustering locally.

On Linux, you can also run everything in one process with the default `SERVER_ROLE=all` (no `SERVER_ROLE` env var needed).

#### SQL Sandbox (Development)

SQL challenges create ephemeral databases on a dedicated Postgres instance. Local infra includes `postgres-runner` on port **5433** (`athena_runner` database).

By default, dev connects to the main Postgres on port 5432. For SQL tasks, point the runner at the dedicated instance:

```bash
export RUNNER_DATABASE_URL=ecto://postgres:postgres@localhost:5433/athena_runner
```

In production, configure `POSTGRES_RUNNER_PASSWORD` and port 5433 via `docker-compose.prod.distributed.yml` (`athena_runner_pg` service).

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

Docker images are built and pushed to GHCR on version tags (`v*`) via `.github/workflows/release.yml`:

- **All-in-One:** `ghcr.io/shekshuev/athena-ex:latest`
- **Web-Only:** `ghcr.io/shekshuev/athena-ex-web:latest`
- **Runner-Only:** `ghcr.io/shekshuev/athena-ex-runner:latest`

A standalone runner tarball (`athena-runner-linux-amd64.tar.gz`) is attached to GitHub Releases.

## Code Runner Note

> The code execution feature relies on [isolate](https://github.com/ioi/isolate), which utilizes Linux kernel features (namespaces, rlimits) to provide a secure sandbox for untrusted code execution.
>
> **Inside Docker:** `isolate` uses Linux **cgroups v2** (`--cg`) for accurate memory tracking (RSS), CPU limits, and multi-threading/fork-bomb protection. The release entrypoint (`rel/overlays/bin/entrypoint`) initializes cgroup directories automatically.
>
> Any container running code execution (`all` or `runner` roles) requires:
>
> - `privileged: true`
> - `pid: "host"`
> - `cgroup: host`
> - Volume mount: `/sys/fs/cgroup:/sys/fs/cgroup:rw`
>
> **On macOS/Windows:** Native execution is not supported — use `docker-compose.dev-runner.yml` or a Linux VM.

## Deployment

Athena supports single-container monoliths and multi-node distributed setups via the `SERVER_ROLE` environment variable.

### Server Roles

- **`all` (Monolith / Combined Mode):** Runs both the Phoenix Web UI and the Code Execution Engine in one container. Ideal for small-to-medium deployments or local development. _(Requires `privileged: true` in Docker.)_
- **`default` (Web Node):** Serves the LiveView UI, HTTP endpoints, Oban, and background tasks. Lightweight, unprivileged container.
- **`runner` (Execution Node):** Headless worker that executes student submissions inside `isolate`. Horizontally scalable. _(Requires `privileged: true` in Docker.)_

If no `SERVER_ROLE` is provided, Athena boots in combined `all` mode.

Web and runner nodes form an Erlang cluster via **libcluster** (Gossip) using a shared `RELEASE_COOKIE`.

### Production Setup

1. Copy `.env.prod.example` to `.env` and fill in secure values (`SECRET_KEY_BASE`, `DATABASE_URL`, `RELEASE_COOKIE`, MinIO credentials, etc.).
2. Choose a deployment compose file (see below).
3. Run `docker compose -f <compose-file> up -d`.
4. Migrations run automatically on web container startup (via `bin/entrypoint` → `bin/migrate`).
5. Create the first admin:

```bash
docker exec athena_web /app/bin/athena eval 'Athena.Release.create_admin("admin", "Admin123!")'
```

### Compose Files

| File | Use case |
|------|----------|
| `docker-compose.prod.yml` | All-in-one: web + runner + Postgres + MinIO |
| `docker-compose.prod.distributed.yml` | Separate web and runner nodes with dedicated SQL-runner Postgres |
| `docker-compose.dev-runner.yml` | Local runner node for development |
| `docker-compose.runner.yml` | Additional runner instances (requires external `athena-network`) |
| `docker-compose.infra.yml` | Local dev infrastructure only |

Refer to these files for the authoritative service definitions rather than copying inline YAML snippets.

### Manual Cluster Startup (Bare Metal / VMs)

1. **Start the Web Node:**

   ```bash
   SERVER_ROLE=default iex --name web@127.0.0.1 --cookie super_secret -S mix phx.server
   ```

2. **Start the Runner Node:**

   ```bash
   SERVER_ROLE=runner iex --name runner1@127.0.0.1 --cookie super_secret -S mix
   ```

## Contributing

We welcome contributions! Please check out our open issues or submit a PR. For major architectural changes, please open an issue first to discuss.

Before submitting, run `mix check` or at minimum `mix precommit`.
