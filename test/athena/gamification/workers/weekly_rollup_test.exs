defmodule Athena.Gamification.Workers.WeeklyRollupTest do
  use Athena.DataCase, async: true

  alias Athena.Gamification.Workers.WeeklyRollup
  alias Athena.Gamification.{AccountStats, XpLedger, XpEvent, LeagueResult, BadgeAward}
  alias Athena.Repo
  import Athena.Factory

  test "rolls up the week passed as a job arg" do
    account = insert(:account)
    block = insert(:block, type: :code)

    XpLedger.record_activity(%{account_id: account.id, block_id: block.id, block_type: :code})

    week_start = Date.beginning_of_week(Date.utc_today())

    Repo.update_all(
      from(e in XpEvent, where: e.account_id == ^account.id),
      set: [inserted_at: DateTime.new!(week_start, ~T[12:00:00], "Etc/UTC")]
    )

    assert :ok =
             WeeklyRollup.perform(%Oban.Job{args: %{"week_start" => Date.to_iso8601(week_start)}})

    stats = Repo.get_by(AccountStats, account_id: account.id)
    assert stats.current_streak_weeks == 1
  end

  test "defaults to the week before the current one when no arg is given" do
    account = insert(:account)
    block = insert(:block, type: :code)

    XpLedger.record_activity(%{account_id: account.id, block_id: block.id, block_type: :code})

    previous_week_start = Date.utc_today() |> Date.beginning_of_week() |> Date.add(-7)

    Repo.update_all(
      from(e in XpEvent, where: e.account_id == ^account.id),
      set: [inserted_at: DateTime.new!(previous_week_start, ~T[12:00:00], "Etc/UTC")]
    )

    assert :ok = WeeklyRollup.perform(%Oban.Job{args: %{}})

    stats = Repo.get_by(AccountStats, account_id: account.id)
    assert stats.current_streak_weeks == 1
    assert stats.last_active_week == previous_week_start
  end

  test "snapshots league standings and awards resulting badges" do
    account = insert(:account)
    cohort = insert(:cohort)
    insert(:cohort_membership, account_id: account.id, cohort_id: cohort.id)

    block = insert(:block, type: :code)
    XpLedger.record_activity(%{account_id: account.id, block_id: block.id, block_type: :code})

    week_start = Date.beginning_of_week(Date.utc_today())

    Repo.update_all(
      from(e in XpEvent, where: e.account_id == ^account.id),
      set: [inserted_at: DateTime.new!(week_start, ~T[12:00:00], "Etc/UTC")]
    )

    Athena.Gamification.create_badge(%{
      "key" => "league-topper",
      "title" => "League Topper",
      "rule" => %{"fact" => "league_top_count", "op" => "gte", "value" => 1}
    })

    assert :ok =
             WeeklyRollup.perform(%Oban.Job{args: %{"week_start" => Date.to_iso8601(week_start)}})

    result = Repo.get_by(LeagueResult, cohort_id: cohort.id, account_id: account.id)
    assert result.tier == :top

    assert Repo.get_by(BadgeAward, account_id: account.id)
  end
end
