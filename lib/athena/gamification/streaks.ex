defmodule Athena.Gamification.Streaks do
  @moduledoc """
  Weekly streak accounting.

  A week (Monday-Sunday) counts as "active" for an account if it earned any
  XP that week — not merely logging in — which matters because this LMS
  isn't reachable 24/7, so streaks track real practice, not presence.
  Computed in a weekly batch (`Athena.Gamification.Workers.WeeklyRollup`),
  not incrementally, since "did last week count" can only be answered once
  the week is over.
  """
  import Ecto.Query
  alias Athena.Repo
  alias Athena.Gamification.{XpEvent, AccountStats}

  @doc """
  Rolls the streak forward for `week_start` (a `Date`, the Monday of the
  week being evaluated — normally the week that just ended).

  - Accounts with XP that week: streak continues (+1) if they were also
    active the week immediately before, otherwise it restarts at 1.
  - Accounts with a live streak but no XP that week: streak resets to 0.
  """
  @spec rollup_week(Date.t()) :: :ok
  def rollup_week(week_start) do
    active_account_ids = active_accounts_for_week(week_start)

    Enum.each(active_account_ids, &upsert_streak(&1, week_start))
    reset_broken_streaks(active_account_ids)

    :ok
  end

  defp active_accounts_for_week(week_start) do
    week_start_dt = DateTime.new!(week_start, ~T[00:00:00], "Etc/UTC")
    week_end_dt = DateTime.new!(Date.add(week_start, 7), ~T[00:00:00], "Etc/UTC")

    XpEvent
    |> where([e], e.amount > 0)
    |> where([e], e.inserted_at >= ^week_start_dt and e.inserted_at < ^week_end_dt)
    |> distinct(true)
    |> select([e], e.account_id)
    |> Repo.all()
  end

  defp upsert_streak(account_id, week_start) do
    previous_week = Date.add(week_start, -7)
    stats = Repo.get_by(AccountStats, account_id: account_id)

    current = (stats && stats.current_streak_weeks) || 0
    longest = (stats && stats.longest_streak_weeks) || 0
    last_active_week = stats && stats.last_active_week

    new_streak = if last_active_week == previous_week, do: current + 1, else: 1
    new_longest = max(longest, new_streak)

    attrs = %{
      account_id: account_id,
      current_streak_weeks: new_streak,
      longest_streak_weeks: new_longest,
      last_active_week: week_start
    }

    # Always insert a fresh struct (never the loaded one) so the conflict is
    # resolved purely by the `account_id` unique index — reusing the loaded
    # struct's own `:id` here would make this insert collide with itself on
    # the primary key as well, not just on `account_id`.
    %AccountStats{}
    |> AccountStats.changeset(attrs)
    |> Repo.insert(
      on_conflict:
        {:replace, [:current_streak_weeks, :longest_streak_weeks, :last_active_week, :updated_at]},
      conflict_target: :account_id
    )
  end

  defp reset_broken_streaks(active_account_ids) do
    AccountStats
    |> where([s], s.current_streak_weeks > 0)
    |> where([s], s.account_id not in ^active_account_ids)
    |> Repo.update_all(set: [current_streak_weeks: 0])
  end
end
