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

Code execution (except SQL) requires Linux with [isolate](https://github.com/ioi/isolate), the language toolchain, and the sandbox facilities described under [Execution containers](#execution-containers). SQL uses dedicated PostgreSQL, MySQL/MariaDB and ClickHouse instances and does not require isolate.

Running `iex -S mix phx.server` from source starts the web application and registers local execution workers for all five language families. Code execution still requires the Linux prerequisites; those workers cannot execute isolate workloads natively on macOS or Windows.

[`docker-compose.dev-runner.yml`](../docker-compose.dev-runner.yml) provides Linux runner containers. For example, this builds and starts the Python runner:

```bash
docker compose -f docker-compose.dev-runner.yml up athena_runner_script
```

**This command alone does not connect a host development server to the runner.** Plain `iex -S mix phx.server` starts an unnamed node, and the source application's combined `all` mode does not configure Gossip discovery. Connecting external runners requires a named distributed web node, a matching Erlang cookie, reachable node addresses, and explicit discovery or connection setup. The dev Compose file uses host networking and `127.0.0.1` node addresses, so host-to-container connectivity must also be checked for the Docker platform in use.

The dev runner cookie is `dev_cookie_12345`; a matching cookie alone is insufficient. There is currently no verified end-to-end macOS/Windows host-to-runner quickstart. The [production topology](#deployment) runs web and runner releases together; a Linux VM is another option for developing with local isolate execution.

#### SQL Sandbox (Development)

SQL challenges select a `database_engine` (`postgresql`, `mysql`, or `clickhouse`); existing content defaults to PostgreSQL. Each attempt gets a temporary database and restricted user. Setup, student code and verification all run with those restricted credentials. Setup runs once per attempt, so reference and student queries see the same seeded data, including generated values. SQL submissions contain one statement; setup scripts may contain multiple statements.

SQL challenges create ephemeral databases on a dedicated Postgres instance. Local infra includes `postgres-runner` on port **5433** (`athena_runner` database).

By default, dev connects to the main Postgres on port 5432. For SQL tasks, point the runner at the dedicated instance:

```bash
export RUNNER_DATABASE_URL=ecto://postgres:postgres@localhost:5433/athena_runner
```

Local infra also starts MariaDB on `127.0.0.1:3307` and ClickHouse on `127.0.0.1:8124`. Both use `runner_secret` for local development. Override connections with `MYSQL_RUNNER_URL` and `CLICKHOUSE_RUNNER_URL`; percent-encode credentials in URLs. MyXQL can also connect to a MySQL server through `MYSQL_RUNNER_URL`. ClickHouse requires the supplied `docker/clickhouse/execution.xml` configuration: table engine grants are enforced, and attempts use the `allowed_table_engines` list under `config :athena, Athena.Execution.Database.ClickHouse` in `config/config.exs`. Defaults include Memory; local MergeTree variants (MergeTree, ReplacingMergeTree, SummingMergeTree, AggregatingMergeTree, CollapsingMergeTree, VersionedCollapsingMergeTree, CoalescingMergeTree, GraphiteMergeTree); Log, TinyLog, StripeLog; Null, Set and Join. GraphiteMergeTree additionally needs a rollup configuration on the ClickHouse server. Restart the runner after editing configuration files; the configured list is applied when each new sandbox user is created. Entries must be explicit engine names; wildcard grants are rejected. Replicated, Shared and Distributed engines remain unavailable. External file/network sources are not granted. Per-user query settings and an independent cancellation deadline enforce execution limits. Result rows and JSON bytes are bounded while fetching; a decoded chunk or individual value can still exceed the client budget before validation.

Execution services use bounded tmpfs and lose all data on restart. Do not store course/application data there. The infra file now uses tmpfs for `postgres-runner` too; any existing `postgres_runner_data` volume is left untouched by this configuration change.

In production, configure `POSTGRES_RUNNER_PASSWORD`, `MYSQL_RUNNER_PASSWORD` and `CLICKHOUSE_RUNNER_PASSWORD` in `.env`. `docker-compose.prod.yml` starts all execution databases. The release/image retains the existing `runner_db` / `runner-db` name and handles all three engines. Copy `docker-compose.prod.yml` and `docker/clickhouse/execution.xml` to the server, preserving the relative XML path. The production Compose file contains all service definitions and does not require `docker-compose.sql-services.yml`; that shared file is still used by development and extra-runner Compose configurations. Changing execution-service credentials requires recreating the corresponding ephemeral service.

## Testing & Code Quality

We use ExUnit for testing, Credo for linting, and Dialyzer for static type checking.

Start PostgreSQL and S3-compatible storage before running tests. The test alias creates and migrates the test database; the test helper checks the storage bucket. Local tests use MinIO, while CI provisions Garage. See [`config/test.exs`](../config/test.exs) for database, bucket, and `DEV_EXTERNAL_HOST` settings. SQL tests require all three execution databases; CI starts MariaDB and ClickHouse with the same Compose configuration. Tests tagged `:isolate` require the Linux sandbox and toolchains.

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

Docker images are built and pushed to GHCR on version tags (`v*`) via the [release workflow](../.github/workflows/release.yml). Each image variant is built and validated separately on `ubuntu-22.04` and `ubuntu-24.04`. All four code-runner variants receive privileged isolate and actual compiler/runtime smoke tests on the runner's real kernel before publication. A failed smoke test blocks that matrix entry's push; other entries continue independently.

See [Images](#images) for the six releases and tag conventions. Docker is the supported deployment target; the workflow does not publish a standalone bare-metal release artifact.

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
| `ghcr.io/shekshuev/athena-ex-runner-db`       | `runner_db`       | SQL challenges (PostgreSQL, MySQL/MariaDB, ClickHouse; no isolate). Unprivileged. |
| `ghcr.io/shekshuev/athena-ex-runner-compiled` | `runner_compiled` | C, C++, Go, Swift, Rust and Zig via isolate. Privileged.           |
| `ghcr.io/shekshuev/athena-ex-runner-script`   | `runner_script`   | Python, JavaScript (Node.js 26 LTS) and TypeScript via isolate. Privileged.    |
| `ghcr.io/shekshuev/athena-ex-runner-jvm` | `runner_jvm` | Java 21 and Kotlin via isolate. Privileged. |
| `ghcr.io/shekshuev/athena-ex-runner-dotnet` | `runner_dotnet` | C# on .NET 10 LTS via isolate. Privileged. |

Combined ("all-in-one") mode only exists when running from source without a
built release – i.e. local development (`iex -S mix phx.server`) and the test
suite. It cannot be reached in production; there's no release that produces it.

### Execution Containers

SQL challenges use `Athena.Execution.DatabaseRunner` with Postgrex, MyXQL and Ch adapters. Each adapter creates restricted temporary users/databases; `runner-db` needs no isolate privileges. Production Compose supplies dedicated PostgreSQL, MariaDB and ClickHouse instances with separate credentials and tmpfs storage.

All non-SQL languages use isolate with Linux namespaces, resource limits, and cgroups v2 (`--cg`). The [release entrypoint](../rel/overlays/bin/entrypoint) prepares cgroup directories for `runner_compiled`, `runner_script`, `runner_jvm` and `runner_dotnet`. Containers need the privileges and writable cgroup access required by that setup.

The production, development and extra-runner Compose files set `privileged: true`, host PID and cgroup namespaces, and a writable `/sys/fs/cgroup` mount for all four code-runner services. Validate cgroup initialization on the target Linux host; CI tests both supported Ubuntu kernels.

Toolchains are installed beneath `/usr/local` and use the sandbox's `/usr` mount; no `/opt` mounts are required. Release builds currently target Linux amd64. The pinned versions in [`install-toolchains.py`](../docker/execution/install-toolchains.py) are:

| Toolchain | Pin | Official source |
| --- | --- | --- |
| Node.js | 26.13.1 LTS | [Node releases](https://nodejs.org/dist/index.json) |
| TypeScript / Node types | 7.0.2 / 26.6.6 | [TypeScript npm metadata](https://registry.npmjs.org/typescript/7.0.2), [Node types metadata](https://registry.npmjs.org/@types/node/26.6.6) |
| Go | 1.27.4 | [Go downloads](https://go.dev/dl/?mode=json) |
| Swift | 6.4.3, Debian 12 | [Swift archive](https://download.swift.org/swift-6.4.3-release/debian12/swift-6.4.3-RELEASE/swift-6.4.3-RELEASE-debian12.tar.gz) |
| Rust | 1.100.0 | [Rust stable manifest](https://static.rust-lang.org/dist/channel-rust-stable.toml) |
| Zig | 0.17.1 | [Zig download metadata](https://ziglang.org/download/index.json) |
| Java | Temurin 21.0.13.1+2 | [Temurin release](https://github.com/adoptium/temurin21-binaries/releases/tag/jdk-21.0.13.1%2B2) |
| Kotlin | 2.4.21 | [Kotlin releases](https://kotlinlang.org/docs/releases.html) |
| .NET SDK / C# | 10.0.404 / 14.0 | [.NET 10 release metadata](https://builds.dotnet.microsoft.com/dotnet/release-metadata/10.0/releases.json) |

C/C++ use Debian Bookworm's GCC packages; Python uses its Python 3 package. These distro package revisions follow the base image's repositories. The isolate source remains pinned to `v2.7`.

The execution contract uses one source file per submission in `/box`. Elixir prepares compiler arguments, environment variables and generated files, then invokes the globally available compiler or interpreter through PATH (`/usr/local/bin:/usr/bin:/bin`). Runner images install no Athena compiler launchers. The toolchain stage installs global `go`, `swiftc` and `zig` symlinks alongside the existing global tools:

| Language | Source | Compiler | Artifact / execution |
| --- | --- | --- | --- |
| C / C++ | `main.c` / `main.cpp` | `gcc` / `g++` | `./out` |
| Go | `main.go` | `go` | `./out` |
| Swift | `main.swift` | `swiftc` | `./out` |
| Rust | `main.rs` | `rustc` | `./out` |
| Zig | `main.zig` | `zig build-exe` | `./out` |
| JavaScript | `main.js` | None | `node main.js` |
| TypeScript | `main.ts` | `tsc` | `node main.js` |
| Java | `Main.java` | `javac --release 21` | `Main.class`; `java Main` |
| Kotlin | `Main.kt` | `kotlinc -jvm-target 21 -include-runtime` | `main.jar`; `java -jar main.jar` |
| C# | `Main.cs` | `dotnet <sdk>/Roslyn/bincore/csc.dll` | `dotnet out/Main.dll` |

TypeScript receives full strict type checking and emits no JavaScript on errors; Node's built-in type stripping is not used. C# invokes the pinned Roslyn compiler directly with .NET 10 reference assemblies, C# 14 and generated implicit usings. It writes a framework-dependent `Main.dll` and its runtime configuration without MSBuild, NuGet or file-lock syscalls blocked by isolate. The CLR single-mapping allocator is selected with `DOTNET_EnableWriteXorExecute=0`: its default double-mapping allocator creates memfd files exceeding the 1 MiB runtime file-size cap. The isolate syscall filter, cgroup memory cap and output/file-size cap remain enabled. Go can use the SDK's official `GOCACHEPROG` interface with the private `athena-go-cache` cache adapter, avoiding disk-cache trim locks without patching the SDK. Swift and Zig use writable submission-local caches. Zig compiles with one job under `strace`, which replaces advisory `flock` calls with successful no-ops before they reach the kernel; the isolate syscall filter remains enabled and submitted executables run without a tracer. Hosts must permit tracing child processes. The compiler CPU, memory and process budgets include the tracer. Swift embeds an rpath to `/usr/local/swift/usr/lib/swift/linux` so native programs can resolve the installed runtime without inherited environment variables. Java and Kotlin resolve their global JDK executables; Kotlin also receives `JAVA_HOME` so vendor scripts do not depend on alternatives links hidden by isolate.

The Elixir runner resolves tools on its global sandbox PATH, follows executable symlinks before entering isolate, and prepares compiler inputs directly:

- Go: set `GOMAXPROCS=2`, private absolute `GOCACHE` and `GOPATH` paths, `GOENV=off`, `GOPROXY=off`, `GOSUMDB=off`, `GOTOOLCHAIN=local` and `CGO_ENABLED=0`; optionally set `GOCACHEPROG` to the installed cache adapter. Invoke `go build -trimpath -o out main.go`.
- Swift: create the private module cache, pass `-swift-version 6 -O -module-cache-path <cache>` and the runtime rpath described above, and emit `out`.
- TypeScript: locate the `@types` directory alongside the resolved global TypeScript package for `--typeRoots`; set the compiler heap to 512 MiB and pass `--strict --noEmitOnError --target ES2022 --module node16 --moduleResolution node16 --types node`.
- C#: resolve the global `dotnet` executable and its symlink target to discover `DOTNET_ROOT` (installed at `/usr/local/share/dotnet`). Select the latest installed .NET 10 SDK and reference pack; generate `references.rsp` from its .NET 10 reference pack, `ImplicitUsings.g.cs` and `out/Main.runtimeconfig.json` before compilation. Invoke global `dotnet` with the Roslyn DLL, reference response file and both sources, using the flags in the smoke script. Set `DOTNET_PROCESSOR_COUNT=2` and `DOTNET_EnableDiagnostics=0` for compilation; preserve the runtime settings and limits above.
- Zig: set private `ZIG_GLOBAL_CACHE_DIR` and `ZIG_LOCAL_CACHE_DIR` paths and invoke `zig build-exe -j1 main.zig -lc -O ReleaseSafe -femit-bin=out`. Where isolate requires cache-lock emulation, prefix only this compilation with the system command `strace -f -qq -o /dev/null -e trace=flock -e inject=flock:retval=0 --`.

The smoke script performs equivalent preparation explicitly to validate the installed toolchains. Production preparation belongs in Elixir; compiler commands receive arguments directly, without a shell launcher. Existing isolation policy and resource budgets still apply.

Build just a toolchain with `docker build --target toolchains -f Dockerfile.runner-script .`, or include isolate and runtime dependencies with `--target sandbox`. For example:

```bash
docker build --target sandbox -f Dockerfile.runner-script -t athena-script-smoke .
docker run --rm --privileged --pid host --cgroupns host \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  --entrypoint /bin/sh athena-script-smoke \
  /usr/local/lib/athena/smoke-languages.sh runner-script
```

Repeat with `compiled`, `jvm` and `dotnet`. The release workflow runs these same real language checks before pushing images. The added toolchains compile with a 1 GiB cgroup cap and separate CPU/wall deadlines. C/C++ retain a 256 MiB compilation budget (10 CPU seconds, 12 wall seconds); runtime smoke checks use 64 MiB, with managed heaps capped at half that budget. The TypeScript check also rejects a deliberate type error. These checks require a disposable Linux host with writable cgroups.

`scripts/deploy.sh` transfers all six images and recreates the web and five runner services. Copy the updated production Compose file and `docker/clickhouse/execution.xml` to the server before using it. Application PostgreSQL and storage services are not recreated by this script.

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
| `docker-compose.prod.yml`       | Production: web + all 5 runner images + Postgres + dedicated SQL-runner Postgres + MinIO                                                    |
| `docker-compose.dev-runner.yml` | Linux runner containers for development; host-node connection requires additional setup (see [Local Code Execution](#local-code-execution)) |
| `docker-compose.runner.yml`     | Additional scalable runner instances (requires external `athena-network`)                                                                   |
| `docker-compose.infra.yml`      | Local dev infrastructure only                                                                                                               |

Refer to these files for the authoritative service definitions rather than copying inline YAML snippets.
