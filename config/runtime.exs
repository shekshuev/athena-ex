import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# There are four named releases (see `releases/0` in mix.exs): `web`,
# `runner_db`, `runner_compiled`, `runner_script`. Each produces its own
# `bin/<name>` script, and Elixir sets RELEASE_NAME to that name at boot —
# that's what this file uses below to derive the node's role, instead of an
# operator-facing env var. `rel/overlays/bin/server` sets PHX_SERVER=true and
# execs `bin/$RELEASE_NAME start`.

# The node's role is never an operator-facing setting: it's baked into which
# release was built and deployed. Elixir sets RELEASE_NAME automatically from
# the release name declared in mix.exs before the node boots. When it's unset
# (running via `mix phx.server` / `mix test` instead of a built release —
# i.e. only in :dev and :test), the node runs every role combined.
{server_role, runner_family} =
  case System.get_env("RELEASE_NAME") do
    "web" ->
      {"default", nil}

    "runner_db" ->
      {"runner", :db}

    "runner_compiled" ->
      {"runner", :compiled}

    "runner_script" ->
      {"runner", :script}

    nil ->
      {"all", nil}

    other ->
      raise "unknown RELEASE_NAME=#{other}, expected one of: web, runner_db, runner_compiled, runner_script"
  end

config :athena, :server_role, server_role
config :athena, :runner_family, runner_family

config :athena, :default_locale, System.get_env("DEFAULT_LOCALE") || "en"

if server_role == "runner" do
  config :athena, ecto_repos: []
end

if server_role != "runner" do
  if System.get_env("PHX_SERVER") do
    config :athena, AthenaWeb.Endpoint, server: true
  end

  config :athena, AthenaWeb.Endpoint,
    http: [port: String.to_integer(System.get_env("PORT", "4000"))]
end

if server_role in ["default", "runner"] do
  config :libcluster,
    topologies: [
      example: [
        strategy: Cluster.Strategy.Gossip,
        config: [
          port: 45892,
          if_addr: "0.0.0.0"
        ]
      ]
    ]
end

if server_role != "runner" do
  config :athena, Oban,
    repo: Athena.Repo,
    queues: [code_execution: System.schedulers_online() * 2, default: 10, maintenance: 2]
end

if config_env() == :prod do
  if server_role != "runner" do
    database_url =
      System.get_env("DATABASE_URL") ||
        raise """
        environment variable DATABASE_URL is missing.
        For example: ecto://USER:PASS@HOST/DATABASE
        """

    maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

    config :athena, Athena.Repo,
      url: database_url,
      pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
      socket_options: maybe_ipv6,
      types: Athena.PostgresTypes

    if System.get_env("FORCE_SSL") == "true" do
      config :athena, AthenaWeb.Endpoint,
        force_ssl: [
          rewrite_on: [:x_forwarded_proto],
          exclude: [
            hosts: ["localhost", "127.0.0.1"]
          ]
        ]
    end

    # The secret key base is used to sign/encrypt cookies and other secrets.
    # A default value is used in config/dev.exs and config/test.exs but you
    # want to use a different value for prod and you most likely don't want
    # to check this value into version control, so we use an environment
    # variable instead.
    secret_key_base =
      System.get_env("SECRET_KEY_BASE") ||
        raise """
        environment variable SECRET_KEY_BASE is missing.
        You can generate one by calling: mix phx.gen.secret
        """

    host = System.get_env("PHX_HOST") || "example.com"

    config :athena, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

    config :athena, AthenaWeb.Endpoint,
      url: [host: host, port: 443, scheme: "https"],
      http: [
        # Enable IPv6 and bind on all interfaces.
        # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
        # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
        # for details about using IPv6 vs IPv4 and loopback vs public addresses.
        ip: {0, 0, 0, 0, 0, 0, 0, 0}
      ],
      secret_key_base: secret_key_base

    config :ex_aws,
      access_key_id: System.get_env("MINIO_ACCESS_KEY") || raise("MINIO_ACCESS_KEY is missing"),
      secret_access_key:
        System.get_env("MINIO_SECRET_KEY") || raise("MINIO_SECRET_KEY is missing"),
      s3: [
        scheme: System.get_env("MINIO_SCHEME") || "https://",
        host: System.get_env("MINIO_HOST") || raise("MINIO_HOST is missing"),
        port: String.to_integer(System.get_env("MINIO_PORT") || "443")
      ]

    config :athena, Athena.Media,
      bucket: System.get_env("MINIO_BUCKET"),
      public_host: System.get_env("MINIO_PUBLIC_HOST"),
      public_port: System.get_env("MINIO_PORT_EXTERNAL")

    media_cron = System.get_env("MEDIA_CLEANUP_CRON") || "0 * * * *"
    gamification_rollup_cron = System.get_env("GAMIFICATION_ROLLUP_CRON") || "5 0 * * MON"

    daily_challenge_cleanup_cron =
      System.get_env("DAILY_CHALLENGE_CLEANUP_CRON") || "15 0 * * *"

    test_run_cleanup_cron = System.get_env("TEST_RUN_CLEANUP_CRON") || "*/15 * * * *"

    config :athena, Oban,
      plugins: [
        Oban.Plugins.Pruner,
        {Oban.Plugins.Cron,
         crontab: [
           {media_cron, Athena.Workers.MediaCleanup, queue: :maintenance},
           {gamification_rollup_cron, Athena.Gamification.Workers.WeeklyRollup,
            queue: :maintenance},
           {daily_challenge_cleanup_cron, Athena.Gamification.Workers.DailyChallengeCleanup,
            queue: :maintenance},
           {test_run_cleanup_cron, Athena.Learning.Workers.TestRunCleanup, queue: :maintenance}
         ]}
      ]
  end

  if server_role == "runner" do
    runner_db_url =
      System.get_env("RUNNER_DATABASE_URL") ||
        "ecto://postgres:#{System.get_env("POSTGRES_RUNNER_PASSWORD", "runner_secret")}@127.0.0.1:5433/postgres"

    config :athena, Athena.Execution.SqlRunner, url: runner_db_url
  end

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :athena, AthenaWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :athena, AthenaWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :athena, Athena.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://hexdocs.pm/swoosh/Swoosh.html#module-installation for details.
end
