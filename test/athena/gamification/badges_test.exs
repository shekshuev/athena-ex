defmodule Athena.Gamification.BadgesTest do
  use Athena.DataCase, async: true

  alias Athena.Gamification.{Badges, Badge, BadgeAward}
  alias Athena.Repo
  import Athena.Factory

  @simple_rule %{"fact" => "total_xp", "op" => "gte", "value" => 100}

  describe "create_badge/1" do
    test "creates a badge with a valid rule" do
      assert {:ok, %Badge{} = badge} =
               Badges.create_badge(%{
                 "key" => "first-hundred",
                 "title" => "First Hundred",
                 "rule" => @simple_rule
               })

      assert badge.is_active
      assert badge.scope == :global
    end

    test "rejects a badge with an invalid rule" do
      assert {:error, changeset} =
               Badges.create_badge(%{
                 "key" => "bad-rule",
                 "title" => "Bad Rule",
                 "rule" => %{"fact" => "not_a_real_fact", "op" => "gte", "value" => 1}
               })

      refute changeset.valid?
    end

    test "rejects a duplicate key" do
      Badges.create_badge(%{"key" => "dup", "title" => "A", "rule" => @simple_rule})

      assert {:error, changeset} =
               Badges.create_badge(%{"key" => "dup", "title" => "B", "rule" => @simple_rule})

      refute changeset.valid?
    end
  end

  describe "test_rule/2" do
    test "evaluates a rule against an account without awarding anything" do
      account = insert(:account)
      insert(:account_stats, account_id: account.id, total_xp: 150)

      assert Badges.test_rule(@simple_rule, account.id)
      assert Badges.list_awards(account.id) == []
    end
  end

  describe "evaluate_for_account/1" do
    test "awards a badge the account now qualifies for" do
      account = insert(:account)
      insert(:account_stats, account_id: account.id, total_xp: 150)

      {:ok, badge} =
        Badges.create_badge(%{"key" => "xp-100", "title" => "XP 100", "rule" => @simple_rule})

      Badges.evaluate_for_account(account.id)

      awards = Badges.list_awards(account.id)
      assert length(awards) == 1
      assert hd(awards).badge.id == badge.id
    end

    test "does not award a badge the account doesn't qualify for yet" do
      account = insert(:account)
      insert(:account_stats, account_id: account.id, total_xp: 10)

      Badges.create_badge(%{"key" => "xp-100", "title" => "XP 100", "rule" => @simple_rule})

      Badges.evaluate_for_account(account.id)

      assert Badges.list_awards(account.id) == []
    end

    test "ignores inactive badges" do
      account = insert(:account)
      insert(:account_stats, account_id: account.id, total_xp: 150)

      {:ok, badge} =
        Badges.create_badge(%{"key" => "xp-100", "title" => "XP 100", "rule" => @simple_rule})

      Badges.update_badge(badge, %{"is_active" => false})
      Badges.evaluate_for_account(account.id)

      assert Badges.list_awards(account.id) == []
    end

    test "does not re-award an already-earned badge" do
      account = insert(:account)
      insert(:account_stats, account_id: account.id, total_xp: 150)

      Badges.create_badge(%{"key" => "xp-100", "title" => "XP 100", "rule" => @simple_rule})

      Badges.evaluate_for_account(account.id)
      Badges.evaluate_for_account(account.id)

      assert length(Badges.list_awards(account.id)) == 1
      assert Repo.aggregate(BadgeAward, :count) == 1
    end

    test "is idempotent even under a direct duplicate insert attempt" do
      account = insert(:account)
      insert(:account_stats, account_id: account.id, total_xp: 150)

      {:ok, badge} =
        Badges.create_badge(%{"key" => "xp-100", "title" => "XP 100", "rule" => @simple_rule})

      Badges.evaluate_for_account(account.id)

      # Simulate a race: the in-memory "already awarded" guard missed it,
      # but the DB unique index still protects against a duplicate award.
      result =
        %BadgeAward{}
        |> BadgeAward.changeset(%{
          account_id: account.id,
          badge_id: badge.id,
          awarded_at: DateTime.truncate(DateTime.utc_now(), :second)
        })
        |> Repo.insert(on_conflict: :nothing, conflict_target: [:account_id, :badge_id])

      assert {:ok, _} = result
      assert Repo.aggregate(BadgeAward, :count) == 1
    end
  end
end
