defmodule Athena.Gamification.Workers.DailyChallengeCleanup do
  @moduledoc """
  Daily Oban cron job: deletes old `gamification_daily_challenges` rows (see
  `Athena.Gamification.DailyChallenges.delete_stale/1`) so the table doesn't
  grow forever — one row per account per active day, most of it useless
  after a few weeks.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 3

  require Logger
  alias Athena.Gamification.DailyChallenges

  @impl Oban.Worker
  def perform(_job) do
    count = DailyChallenges.delete_stale()

    Logger.info("[Gamification.DailyChallengeCleanup] Deleted #{count} stale daily challenge(s)")

    :ok
  end
end
