defmodule Athena.Gamification.StreaksTest do
  use Athena.DataCase, async: true

  alias Athena.Gamification.{Streaks, AccountStats, XpLedger}
  alias Athena.Repo
  import Athena.Factory

  # Any Monday works as a fixed reference week for these tests.
  @week1 ~D[2026-01-05]
  @week2 ~D[2026-01-12]
  @week3 ~D[2026-01-19]

  defp award_xp_at(account_id, %Date{} = date) do
    block = insert(:block, type: :code)

    XpLedger.record_activity(%{account_id: account_id, block_id: block.id, block_type: :code})

    # record_activity always stamps "now" — backdate the event so it lands
    # in the week under test.
    dt = DateTime.new!(date, ~T[12:00:00], "Etc/UTC")

    Repo.update_all(
      from(e in Athena.Gamification.XpEvent, where: e.account_id == ^account_id),
      set: [inserted_at: dt]
    )
  end

  describe "rollup_week/1" do
    test "a first active week starts the streak at 1" do
      account = insert(:account)
      award_xp_at(account.id, @week1)

      Streaks.rollup_week(@week1)

      stats = Repo.get_by(AccountStats, account_id: account.id)
      assert stats.current_streak_weeks == 1
      assert stats.longest_streak_weeks == 1
      assert stats.last_active_week == @week1
    end

    test "consecutive active weeks increment the streak" do
      account = insert(:account)
      award_xp_at(account.id, @week1)
      Streaks.rollup_week(@week1)

      award_xp_at(account.id, @week2)
      Streaks.rollup_week(@week2)

      stats = Repo.get_by(AccountStats, account_id: account.id)
      assert stats.current_streak_weeks == 2
      assert stats.longest_streak_weeks == 2
    end

    test "a gap week resets the streak back to 1, keeping the longest streak on record" do
      account = insert(:account)

      award_xp_at(account.id, @week1)
      Streaks.rollup_week(@week1)
      award_xp_at(account.id, @week2)
      Streaks.rollup_week(@week2)

      # week3 has no activity for this account — rollup_week(week3) sees them
      # inactive and resets. Then a later active week restarts at 1.
      Streaks.rollup_week(@week3)

      stats = Repo.get_by(AccountStats, account_id: account.id)
      assert stats.current_streak_weeks == 0
      assert stats.longest_streak_weeks == 2

      later_week = Date.add(@week3, 7)
      award_xp_at(account.id, later_week)
      Streaks.rollup_week(later_week)

      stats = Repo.get_by(AccountStats, account_id: account.id)
      assert stats.current_streak_weeks == 1
      assert stats.longest_streak_weeks == 2
    end

    test "does not touch accounts with no activity at all" do
      account = insert(:account)

      Streaks.rollup_week(@week1)

      refute Repo.get_by(AccountStats, account_id: account.id)
    end

    test "activity in an unrelated week does not count toward the evaluated week" do
      account = insert(:account)
      award_xp_at(account.id, @week2)

      Streaks.rollup_week(@week1)

      stats = Repo.get_by(AccountStats, account_id: account.id)
      assert stats.current_streak_weeks == 0
      assert stats.last_active_week == nil
    end
  end
end
