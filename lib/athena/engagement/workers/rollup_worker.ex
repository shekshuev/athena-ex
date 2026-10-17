defmodule Athena.Engagement.Workers.RollupWorker do
  @moduledoc """
  Oban cron job that folds newly recorded engagement events into the daily
  rollups (`Athena.Engagement.Rollups.process_new_events/1`). Unique while
  queued or running, so a slow run (the first backfill) never overlaps the
  next tick.
  """
  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: :infinity, states: [:available, :scheduled, :executing, :retryable]]

  require Logger

  alias Athena.Engagement.Rollups

  # Each batch commits its own transaction and advances the cursor, so a run
  # cut short by the timeout loses nothing: the next tick resumes from there.
  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(15)

  @impl Oban.Worker
  def perform(_job) do
    processed = Rollups.process_new_events()
    if processed > 0, do: Logger.info("[Engagement.RollupWorker] folded #{processed} events")
    :ok
  end
end
