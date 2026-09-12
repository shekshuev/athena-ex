defmodule Athena.Gamification.LeaguesTest do
  use Athena.DataCase, async: true

  alias Athena.Gamification.{Leagues, LeagueResult, XpLedger}
  alias Athena.Repo
  import Athena.Factory

  defp award_this_week(account_id, amount) do
    block = insert(:block, type: :code)
    XpLedger.record_activity(%{account_id: account_id, block_id: block.id, block_type: :code})
    # code XP is 15 per block; award more blocks to reach arbitrary totals.
    remaining = amount - 15

    if remaining > 0 do
      award_this_week(account_id, remaining)
    end
  end

  describe "current_week_standings/1" do
    test "ranks cohort members by this week's XP, richest first" do
      cohort = insert(:cohort)
      [a, b, c] = insert_list(3, :account)

      for account <- [a, b, c],
          do: insert(:cohort_membership, account_id: account.id, cohort_id: cohort.id)

      award_this_week(a.id, 30)
      award_this_week(b.id, 60)
      # c earns nothing this week.

      standings = Leagues.current_week_standings(cohort.id)
      by_account = Map.new(standings, &{&1.account_id, &1})

      assert by_account[b.id].rank == 1
      assert by_account[a.id].rank == 2
      assert by_account[c.id].rank == 3
      assert by_account[c.id].tier == :quiet
      assert by_account[c.id].weekly_xp == 0
    end

    test "only the top tier is marked :top, everyone else active or quiet" do
      cohort = insert(:cohort)
      accounts = insert_list(5, :account)

      for account <- accounts,
          do: insert(:cohort_membership, account_id: account.id, cohort_id: cohort.id)

      Enum.each(accounts, &award_this_week(&1.id, 15))

      standings = Leagues.current_week_standings(cohort.id)
      tiers = Enum.map(standings, & &1.tier)

      # top_tier_fraction = 0.3, ceil(5 * 0.3) = 2
      assert Enum.count(tiers, &(&1 == :top)) == 2
      assert Enum.count(tiers, &(&1 == :active)) == 3
    end
  end

  describe "sandwich_view/2" do
    test "returns the top 3 plus the viewer's own rank +-2" do
      standings =
        for rank <- 1..10 do
          %{account_id: "acc-#{rank}", weekly_xp: 100 - rank, rank: rank, tier: :active}
        end

      view = Leagues.sandwich_view(standings, "acc-8")
      ranks = Enum.map(view, & &1.rank)

      assert ranks == [1, 2, 3, 6, 7, 8, 9, 10]
    end

    test "returns just the top 3 if the viewer isn't in the standings" do
      standings =
        for rank <- 1..5 do
          %{account_id: "acc-#{rank}", weekly_xp: 10, rank: rank, tier: :active}
        end

      view = Leagues.sandwich_view(standings, "ghost")
      assert Enum.map(view, & &1.rank) == [1, 2, 3]
    end
  end

  describe "visible_standings/2" do
    test "hides :quiet members from other viewers but keeps the viewer's own row" do
      cohort = insert(:cohort)
      [active, quiet] = insert_list(2, :account)

      for account <- [active, quiet],
          do: insert(:cohort_membership, account_id: account.id, cohort_id: cohort.id)

      award_this_week(active.id, 15)

      view = Leagues.visible_standings(cohort.id, active.id)
      refute Enum.any?(view, &(&1.account_id == quiet.id))

      own_view = Leagues.visible_standings(cohort.id, quiet.id)
      assert Enum.any?(own_view, &(&1.account_id == quiet.id))
    end

    test "hides members who opted out via profile metadata, except from themselves" do
      cohort = insert(:cohort)
      viewer = insert(:account)
      opted_out = insert(:account)

      insert(:profile, owner: opted_out, metadata: %{"show_in_league" => false})

      for account <- [viewer, opted_out],
          do: insert(:cohort_membership, account_id: account.id, cohort_id: cohort.id)

      award_this_week(viewer.id, 15)
      award_this_week(opted_out.id, 15)

      view = Leagues.visible_standings(cohort.id, viewer.id)
      refute Enum.any?(view, &(&1.account_id == opted_out.id))

      own_view = Leagues.visible_standings(cohort.id, opted_out.id)
      assert Enum.any?(own_view, &(&1.account_id == opted_out.id))
    end
  end

  describe "quiet_members/1" do
    test "lists members with no XP this week" do
      cohort = insert(:cohort)
      [active, quiet] = insert_list(2, :account)

      for account <- [active, quiet],
          do: insert(:cohort_membership, account_id: account.id, cohort_id: cohort.id)

      award_this_week(active.id, 15)

      quiet_ids = Leagues.quiet_members(cohort.id) |> Enum.map(& &1.account_id)
      assert quiet_ids == [quiet.id]
    end
  end

  describe "snapshot_week/1" do
    test "persists a LeagueResult row per cohort member for the given week" do
      cohort = insert(:cohort)
      account = insert(:account)
      insert(:cohort_membership, account_id: account.id, cohort_id: cohort.id)

      week_start = Date.beginning_of_week(Date.utc_today())
      award_this_week(account.id, 30)

      Leagues.snapshot_week(week_start)

      result =
        Repo.get_by(LeagueResult,
          cohort_id: cohort.id,
          account_id: account.id,
          week_start: week_start
        )

      assert result.weekly_xp == 30
      assert result.rank == 1
    end

    test "only snapshots academic cohorts, not team ones" do
      team = insert(:cohort, type: :team)
      account = insert(:account)
      insert(:cohort_membership, account_id: account.id, cohort_id: team.id)

      week_start = Date.beginning_of_week(Date.utc_today())
      Leagues.snapshot_week(week_start)

      refute Repo.get_by(LeagueResult, cohort_id: team.id)
    end

    test "is idempotent — re-snapshotting the same week replaces, not duplicates" do
      cohort = insert(:cohort)
      account = insert(:account)
      insert(:cohort_membership, account_id: account.id, cohort_id: cohort.id)

      week_start = Date.beginning_of_week(Date.utc_today())
      award_this_week(account.id, 15)

      Leagues.snapshot_week(week_start)
      Leagues.snapshot_week(week_start)

      assert Repo.aggregate(LeagueResult, :count) == 1
    end
  end
end
