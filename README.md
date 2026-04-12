# Athena LMS

Athena is a modular Learning Management System (LMS) built as a unified Elixir monolith.
The project is under active development and not production-ready yet.

> **Work in progress.** Most of the system is not production-ready yet.

## Features

- **Role-Based Access Control (RBAC):** Students, Instructors, Admins.
- **Code Runner:** Secure execution of student code via [isolate](https://github.com/ioi/isolate).
- **Course Studio:** Instructor tools for creating and managing content.
- **Modern UI:** Clean, reactive, and responsive interface built with Phoenix LiveView, Tailwind CSS, and daisyUI.

## Tech Stack

### Core

- **Language:** Elixir 1.18+
- **Framework:** Phoenix 1.8+
- **Frontend:** Phoenix LiveView (Server-side rendering with real-time updates)
- **Database:** PostgreSQL + Ecto
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

> The code execution feature relies on [isolate](https://github.com/ioi/isolate), which utilizes Linux kernel features (cgroups, namespaces).
>
> **On Linux:** Ensure `isolate` is installed and you have sudo rights (or configured sudoers).
>
> **On macOS/Windows:** You cannot run the code execution engine natively. Development involving code execution should be done inside a Linux VM or Docker container.
