# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :athena,
  ecto_repos: [Athena.Repo],
  generators: [timestamp_type: :utc_datetime]

# Everything is stored and compared in UTC. The app timezone defines where a
# "day"/"week" starts for server-side logic (daily challenges, weekly rollups,
# cron) and is the display fallback when the browser hasn't reported its own.
config :athena, :app_timezone, "Europe/Moscow"

config :elixir, :time_zone_database, Tz.TimeZoneDatabase

# Configure the endpoint
config :athena, AthenaWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: AthenaWeb.ErrorHTML, json: AthenaWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Athena.PubSub,
  live_view: [signing_salt: "TXlRIble"]

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :athena, Athena.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  athena: [
    args:
      ~w(js/app.js --bundle --target=es2015 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

config :flop, repo: Athena.Repo

# ExAws (S3/MinIO) defaults to :hackney, but per this project's guidelines
# we use Req for HTTP everywhere. Also sidesteps a real hackney bug
# (`hackney:test_host_cidr/2` has no clause for a 1-element address list -
# github.com/benoitc/hackney/blob/1.25.0/src/hackney.erl#L793) that crashes
# every ExAws request, including the test bucket check in
# test/test_helper.exs, whenever NO_PROXY/no_proxy contains a CIDR entry
# (e.g. auto-injected by WSL2 or a VPN client) - previously worked around by
# unsetting those env vars before running mix.
config :ex_aws, http_client: ExAws.Request.Req

config :mime, :types, %{
  "video/x-matroska" => ["mkv"],
  "video/x-msvideo" => ["avi"],
  "audio/flac" => ["flac"],
  "audio/mpeg" => ["mp3"],
  "audio/wav" => ["wav"],
  "application/x-rar-compressed" => ["rar"],
  "application/x-7z-compressed" => ["7z"],
  "text/x-python" => ["py"],
  "text/x-c++src" => ["cpp"],
  "text/x-csrc" => ["c"],
  "text/x-chdr" => ["h"],
  "text/javascript" => ["js"],
  "text/typescript" => ["ts"],
  "text/markdown" => ["md"],
  "text/csv" => ["csv"],
  "application/json" => ["json"]
}

config :mime, :extensions, %{
  "rar" => "application/x-rar-compressed",
  "py" => "text/x-python",
  "cpp" => "text/x-c++src",
  "c" => "text/x-csrc",
  "h" => "text/x-chdr",
  "js" => "text/javascript",
  "ts" => "text/typescript",
  "md" => "text/markdown",
  "json" => "application/json"
}

config :athena, Athena.Execution.Worker, timeout: 60_000
config :athena, Athena.Execution.TestWorker, timeout: 60_000

config :athena, Athena.Execution.SqlRunner,
  url: "ecto://postgres:postgres@localhost:5432/postgres"

config :athena, Athena.Engagement,
  default_expected_seconds: nil,
  default_fast_ratio_threshold: 0.4,
  histogram_buckets: 10,
  histogram_max_seconds: 1200,
  min_sample_size_for_percentile: 15,
  block_stats_idle_timeout_minutes: 30,
  min_scroll_percent_for_text: 70,
  paste_ratio_nudge_threshold: 0.8,
  video_skip_ratio_threshold: 0.3,
  panic_debug_gap_seconds: 10,
  panic_debug_min_bursts: 3,
  concern_backtrack_rate_threshold: 0.4,
  concern_hesitation_rate_threshold: 0.4,
  concern_dwell_ratio_threshold: 0.5,
  slow_dwell_ratio_threshold: 2.0,
  student_radar_slacking_threshold: 2,
  student_radar_struggling_threshold: 2,
  student_radar_integrity_threshold: 1,
  student_radar_default_window_days: 7,
  exam_focus_loss_threshold: 3,
  exam_paste_ratio_threshold: 0.6,
  exam_hard_evidence_red_threshold: 2,
  exam_behavioral_outliers_red_threshold: 2,
  exam_percentile_outlier_threshold: 90,
  proctoring_monitor_idle_timeout_minutes: 180

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
