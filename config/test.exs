import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :athena, Athena.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "athena_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2,
  types: Athena.PostgresTypes

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

# Config for local MinIO 
config :ex_aws,
  access_key_id: "minioadmin",
  secret_access_key: "minioadmin",
  s3: [
    scheme: "http://",
    host: "localhost",
    port: 9000
  ]

config :athena, Athena.Media, bucket: "athena-test-#{System.get_env("MIX_TEST_PARTITION") || "0"}"
