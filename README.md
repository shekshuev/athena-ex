# Athena LMS

Athena is a modular Learning Management System (LMS) built as a unified Elixir monolith.

> **Status: Active Development / Beta.** Athena is currently being used in real-world educational scenarios. While core features are stable and production-tested, internal APIs and schemas may evolve as we continue to scale.

## Features

- **Dynamic Course Builder:** Drag-and-drop syllabus editor with reusable library blocks, templates, and rich-text WYSIWYG editing powered by Tiptap.
- **Advanced Progression Engine:** Granular control over student paths with completion rules (button clicks, auto-grading gates) and time-based access locks (Waterline progression).
- **Interactive Quizzes & Exams:** Support for single/multiple choice, exact match (CTF flags), and open essays with instructor review. Includes built-in anti-cheat mechanisms (e.g., window blur detection).
- **Code Execution Sandbox:** Secure, multi-language code runner backed by [isolate](https://github.com/ioi/isolate) with fine-grained time and memory limits, and hidden test cases.
- **Team & Cohort Management:** Shared team progress, isolated cohort schedules, and strict Role-Based Access Control (RBAC) across Students, Instructors, and Admins.
- **Direct S3 Media Uploads:** Native, presigned URL integration with MinIO/AWS S3 for fast, secure file handling and massive attachments.

## Tech Stack

### Core

- **Language:** Elixir 1.18+
- **Framework:** Phoenix 1.8+
- **Frontend:** Phoenix LiveView (Server-side rendering with real-time PubSub updates)
- **Database:** PostgreSQL + Ecto
- **Background Jobs:** Oban
- **Caching:** In-memory ETS via Cachex
- **Auth:** Custom session-based authentication with Argon2 hashing
- **UI Components:** Tailwind CSS, daisyUI, Heroicons

## Getting Started

### Prerequisites

- Erlang/OTP 28+ and Elixir 1.18+
- PostgreSQL 15+
- Node.js 20+ (optional, depends on your asset pipeline needs)

### Installation

#### Clone the repository

```bash
git clone https://github.com/shekshuev/athena-ex.git
cd athena-ex
```

#### Project Setup

We use Docker Compose to spin up local infrastructure (PostgreSQL & MinIO) with zero configuration required.

```bash
# 1. Start the local databases and object storage
docker-compose -f docker-compose.infra.yml up -d

# 2. Install dependencies, create DB, run migrations, and build assets
mix setup
```

#### Start the Server

```bash
iex -S mix phx.server
```

The application will be available at `http://localhost:4000`. MinIO console is available at `http://localhost:9001` (Creds: `minioadmin` / `minioadmin`).

## Production Deployment

For production, Athena uses a separate `docker-compose.prod.yml` which relies entirely on environment variables for security.

1. Copy `.env.example` to `.env` and fill in your secure passwords.
2. Build your Elixir Docker image.
3. Run `docker-compose -f docker-compose.prod.yml up -d`.

## Production First Run

After the containers are up, create your first admin:

```bash
# Create admin
docker exec athena_web /app/bin/athena eval "Athena.Release.create_admin(\"admin\", \"Admin123!\")"
```

## Manual User Creation (IEx)

To create your first admin user manually, open the Elixir interactive shell (`iex -S mix`) and run the following commands:

```elixir
iex(1)> alias Athena.Identity.{Roles, Accounts, Role}

# 1. Create a basic admin role
iex(2)> {:ok, %Role{id: role_id}} = Roles.create_role(%{"name" => "admin", "permissions" => ["admin"], "policies" => %{}})

# 2. Create the account linked to that role
iex(3)> {:ok, _account} = Accounts.create_account(%{"login" => "admin", "password" => "Admin123!", "role_id" => role_id})
```

## Testing & Code Quality

We use ExUnit for testing, Credo for linting, and Dialyzer for static type checking.

```bash
# Run the test suite:
mix test

# Run the complete pipeline (Formatter, Credo strict, Dialyzer, Tests):
mix check
```

## CI/CD

The GitHub Actions pipeline handles:

- Code formatting checks
- Strict linting (Credo)
- Static type checking (Dialyzer)
- Unit and Integration Tests (ExUnit)

Triggered on PRs and pushes to `main` and `develop`.

## Code Runner Note

> The code execution feature relies on [isolate](https://github.com/ioi/isolate), which utilizes Linux kernel features (namespaces, rlimits) to provide a secure sandbox for untrusted code execution.
>
> **Inside Docker:** `isolate` uses Linux **cgroups v2** (`--cg`) for accurate memory tracking (RSS), CPU limits, and multi-threading/fork-bomb protection.
>
> Any container running code execution (`all` or `runner` roles) requires:
>
> - `privileged: true`
> - `pid: "host"`
> - `cgroup: host`
> - Volume mount: `/sys/fs/cgroup:/sys/fs/cgroup:rw`
>
> **On macOS/Windows:** Native execution is not supported.

---

## Deployment Modes & Architecture

Athena supports both single-container monoliths and multi-node distributed setups out of a single codebase using the `SERVER_ROLE` environment variable.

### Available Server Roles

- **`all` (Monolith / Combined Mode):** Runs both the Phoenix Web UI and the Code Execution Engine in a single container. Ideal for small-to-medium deployments, single-node VPS, or local development. _(Requires `privileged: true` in Docker)_.
- **`default` (Web Node):** Serves the Phoenix LiveView UI, HTTP endpoints, and manages background database/storage tasks. Lightweight, unprivileged container.
- **`runner` (Execution Node):** Headless worker node that executes student submissions inside `isolate`. Can be scaled horizontally across multiple servers. _(Requires `privileged: true` in Docker)_.

---

## Production Deployment

Official Docker images are automatically built for all deployment scenarios:

- **All-in-One Image:** `ghcr.io/shekshuev/athena-ex:latest`
- **Web-Only Image:** `ghcr.io/shekshuev/athena-ex-web:latest`
- **Runner-Only Image:** `ghcr.io/shekshuev/athena-ex-runner:latest`

### Option 1: All-in-One Deployment

Spin up the full stack (Web + Runner + DB + Storage) in a single compose configuration:

```yaml
athena:
  image: ghcr.io/shekshuev/athena-ex:latest
  container_name: athena_prod
  privileged: true
  pid: "host"
  cgroup: host
  restart: always
  env_file:
    - .env
  environment:
    - SERVER_ROLE=all
    - RELEASE_COOKIE=${RELEASE_COOKIE}
  volumes:
    - /sys/fs/cgroup:/sys/fs/cgroup:rw
  ports:
    - "${WEB_PORT_EXTERNAL:-80}:4000"
  depends_on:
    - postgres
    - minio
  networks:
    - athena-network

networks:
  athena-network:
    driver: bridge

volumes:
  postgres_data:
  minio_data:
```

### Option 2: Distributed Deployment (Web + Scalable Runners)

In distributed mode, Web and Runner nodes form an Erlang cluster via `libcluster` using a shared `RELEASE_COOKIE` over `network_mode: "host"` or container networking.

```yaml
version: "3.8"

services:
  athena_web:
    image: ghcr.io/shekshuev/athena-ex-web:latest
    container_name: athena_web
    restart: always
    network_mode: "host"
    env_file:
      - .env
    environment:
      - SERVER_ROLE=default
      - RELEASE_DISTRIBUTION=name
      - RELEASE_NODE=web@127.0.0.1
      - RELEASE_COOKIE=${RELEASE_COOKIE}
    depends_on:
      - postgres
      - minio

  athena_runner:
    image: ghcr.io/shekshuev/athena-ex-runner:latest
    container_name: athena_runner
    privileged: true
    pid: "host"
    cgroup: host
    restart: always
    network_mode: "host"
    env_file:
      - .env
    environment:
      - SERVER_ROLE=runner
      - RELEASE_DISTRIBUTION=name
      - RELEASE_NODE=runner1@127.0.0.1
      - RELEASE_COOKIE=${RELEASE_COOKIE}
    volumes:
      - /sys/fs/cgroup:/sys/fs/cgroup:rw
```

### Manual Cluster Startup (IEx)

If running directly on bare-metal or separate VMs:

1. **Start the Web Node:**

   ```bash
   SERVER_ROLE=default iex --name web@127.0.0.1 --cookie super_secret -S mix phx.server
   ```

2. **Start the Runner Node:**
   ```bash
   SERVER_ROLE=runner iex --name runner1@127.0.0.1 --cookie super_secret -S mix
   ```

_Note: If no `SERVER_ROLE` is provided, Athena will boot in a combined mode._

## Contributing

We welcome contributions! Please check out our open issues or submit a PR. For major architectural changes, please open an issue first to discuss.
