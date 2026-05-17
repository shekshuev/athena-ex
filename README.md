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

> The code execution feature relies on [isolate](https://github.com/ioi/isolate), which utilizes Linux kernel features (cgroups, namespaces) to provide a truly secure sandbox, preventing malicious system calls and enforcing strict resource constraints.
>
> **On Linux:** Ensure `isolate` is installed and you have sudo rights (or configured sudoers).
>
> **On macOS/Windows:** You cannot run the code execution engine natively. Development involving code execution should be done inside a Linux VM or Docker container.

## Contributing

We welcome contributions! Please check out our open issues or submit a PR. For major architectural changes, please open an issue first to discuss.
