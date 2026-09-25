import Config

# Keep day boundaries and rendered times deterministic in tests.
config :athena, :app_timezone, "Etc/UTC"

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.

external_host = System.get_env("DEV_EXTERNAL_HOST", "localhost")

config :athena, Athena.Repo,
  username: "postgres",
  password: "postgres",
  hostname: external_host,
  database: "athena_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 3,
  queue_target: 5_000,
  types: Athena.PostgresTypes

config :athena, Athena.Execution.SqlRunner,
  url: System.get_env("RUNNER_DATABASE_URL") || "ecto://postgres:postgres@localhost:5432/postgres"

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :athena, AthenaWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "ziDRVH3ZFkXcZF66aP18r59BHiItQ91xfRFeOmgcF5ED1X2NUjHuiN1qJ0QQoa7u",
  server: false

# In test we don't send emails
config :athena, Athena.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Local dev still runs MinIO (see docker-compose.infra.yml) with its fixed
# root credentials. CI runs Garage instead (see .github/workflows/ci.yml) -
# Garage has no fixed root user, so CI provisions a real access key/secret
# per run and exports them as GARAGE_ACCESS_KEY_ID/GARAGE_SECRET_ACCESS_KEY;
# the "minioadmin" fallback below keeps local dev unchanged when those
# aren't set.
config :ex_aws,
  access_key_id: System.get_env("GARAGE_ACCESS_KEY_ID", "minioadmin"),
  secret_access_key: System.get_env("GARAGE_SECRET_ACCESS_KEY", "minioadmin"),
  s3: [
    scheme: "http://",
    host: external_host,
    port: 9000
  ]

config :athena, Athena.Media, bucket: "athena-test-#{System.get_env("MIX_TEST_PARTITION") || "0"}"

config :athena, Oban,
  testing: :manual,
  queues: false,
  plugins: false

config :athena, :server_role, "all"

# These global singletons (see `Athena.Application.background_listeners/0`)
# can never be granted access to a test's sandboxed DB connection, so
# leaving them running just spams every test run with harmless-but-noisy
# DBConnection.OwnershipError logs whenever any test broadcasts a domain
# event. Their handler logic is unit-tested directly instead (calling
# `handle_info/2` in the test's own sandboxed process).
config :athena, :start_background_listeners, false
