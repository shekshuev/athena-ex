defmodule Athena.Engagement.Workers.EnsurePartitions do
  @moduledoc """
  Daily Oban cron job: keeps the monthly `engagement_events` partitions
  created ahead of time (`Athena.Engagement.Partitions.ensure/1`).
  """
  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: :infinity, states: [:available, :scheduled, :executing, :retryable]]

  alias Athena.Engagement.Partitions

  @impl Oban.Worker
  def perform(_job) do
    Partitions.ensure()
    :ok
  end
end
