defmodule Athena.Engagement.Workers.MoveLegacyEvents do
  @moduledoc """
  Oban cron job that moves the events recorded before `engagement_events`
  was partitioned from `engagement_events_legacy` into the partitioned
  table, a batch at a time (`Athena.Engagement.Partitions.move_legacy_batch/1`),
  and drops the old table once it is empty. A no-op from then on.

  Each run moves at most `@max_batches` batches, so it never holds the
  maintenance queue for long; the cron picks it up again a few minutes
  later until everything is across.
  """
  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: :infinity, states: [:available, :scheduled, :executing, :retryable]]

  require Logger
  alias Athena.Engagement.Partitions

  @batch_size 5_000
  @max_batches 60

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(10)

  @impl Oban.Worker
  def perform(_job) do
    moved =
      Enum.reduce_while(1..@max_batches, 0, fn _batch, total ->
        case Partitions.move_legacy_batch(@batch_size) do
          :done -> {:halt, total}
          0 -> {:halt, total}
          count -> {:cont, total + count}
        end
      end)

    if moved > 0, do: Logger.info("[Engagement.MoveLegacyEvents] moved #{moved} events")

    Partitions.drop_empty_legacy()
    :ok
  end
end
