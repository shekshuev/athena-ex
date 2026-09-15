defmodule Athena.Learning.Workers.TestRunCleanup do
  @moduledoc """
  Cron backstop for `Athena.Learning.TestRuns`: sweeps and purges any
  test-run session that's past its `expires_at` but still marked `:active`
  — i.e. one whose modal-close cleanup never ran (crashed browser, dropped
  connection, killed tab).
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 3

  require Logger
  alias Athena.Learning.TestRuns

  @impl Oban.Worker
  def perform(_job) do
    count = TestRuns.sweep_expired()

    Logger.info("[Learning.TestRunCleanup] Cleaned up #{count} expired test run session(s)")

    :ok
  end
end
