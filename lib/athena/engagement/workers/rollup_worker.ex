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

  @impl Oban.Worker
  def perform(_job) do
    processed = Rollups.process_new_events()
    if processed > 0, do: Logger.info("[Engagement.RollupWorker] folded #{processed} events")
    :ok
  end
end
