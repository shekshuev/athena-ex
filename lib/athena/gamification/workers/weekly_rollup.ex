defmodule Athena.Gamification.Workers.WeeklyRollup do
  @moduledoc """
  Weekly Oban cron job: evaluates the week that just ended and rolls
  account streaks forward or resets them (see `Athena.Gamification.Streaks`).

  Accepts an optional `"week_start"` (ISO date, the Monday of the week to
  evaluate) job arg for backfills/manual runs; defaults to the week
  immediately before the current one.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 3

  import Ecto.Query
  require Logger
  alias Athena.Repo
  alias Athena.Gamification.{Streaks, Leagues, Badges, LeagueResult}

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    week_start = week_start_from_args(args) || previous_week_start()

    Logger.info("[Gamification.WeeklyRollup] Rolling up week starting #{week_start}")

    Streaks.rollup_week(week_start)
    Leagues.snapshot_week(week_start)
    evaluate_league_badges(week_start)

    :ok
  end

  # League-top badges depend on this week's LeagueResult rows, which just
  # got written above — re-run the badge evaluator for everyone who has a
  # result this week rather than waiting for their next unrelated activity.
  defp evaluate_league_badges(week_start) do
    LeagueResult
    |> where([r], r.week_start == ^week_start)
    |> select([r], r.account_id)
    |> distinct(true)
    |> Repo.all()
    |> Enum.each(&Badges.evaluate_for_account/1)
  end

  defp week_start_from_args(%{"week_start" => date_string}) when is_binary(date_string) do
    case Date.from_iso8601(date_string) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp week_start_from_args(_), do: nil

  defp previous_week_start do
    Athena.TimeZones.this_week_start()
    |> Date.add(-7)
  end
end
