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

1. **Clone the repository:**

   ```bash
   git clone https://github.com/shekshuev/athena-ex.git
   cd athena-ex
   ```

2. **Install dependencies:**

   ```bash
   mix deps.get
   ```

3. **Database Setup:**
   Ensure PostgreSQL is running. Configure your credentials in `config/dev.exs` if they differ from the defaults, then run:

   ```bash
   mix ecto.setup
   ```

   _This command creates the database, runs migrations, and executes the seed script (`priv/repo/seeds.exs`)._

4. **Start the Server:**

   ```bash
   iex -S mix phx.server
   ```

   The application will be available at `http://localhost:4000`.

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
