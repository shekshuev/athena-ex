defmodule Athena.Gamification.RuleEngineTest do
  use Athena.DataCase, async: true

  alias Athena.Gamification.RuleEngine
  import Athena.Factory

  setup do
    account = insert(:account)
    insert(:account_stats, account_id: account.id, total_xp: 500, current_streak_weeks: 3)
    %{account: account}
  end

  describe "evaluate/2 — leaf comparisons" do
    test "gte", %{account: account} do
      assert RuleEngine.evaluate(
               %{"fact" => "total_xp", "op" => "gte", "value" => 500},
               account.id
             )

      assert RuleEngine.evaluate(
               %{"fact" => "total_xp", "op" => "gte", "value" => 100},
               account.id
             )

      refute RuleEngine.evaluate(
               %{"fact" => "total_xp", "op" => "gte", "value" => 501},
               account.id
             )
    end

    test "lte, gt, lt, eq, ne", %{account: account} do
      assert RuleEngine.evaluate(
               %{"fact" => "total_xp", "op" => "lte", "value" => 500},
               account.id
             )

      refute RuleEngine.evaluate(
               %{"fact" => "total_xp", "op" => "gt", "value" => 500},
               account.id
             )

      assert RuleEngine.evaluate(
               %{"fact" => "total_xp", "op" => "lt", "value" => 501},
               account.id
             )

      assert RuleEngine.evaluate(
               %{"fact" => "total_xp", "op" => "eq", "value" => 500},
               account.id
             )

      assert RuleEngine.evaluate(%{"fact" => "total_xp", "op" => "ne", "value" => 1}, account.id)
    end

    test "an unknown fact evaluates to 0, so gte 0 is true but gte 1 is false", %{
      account: account
    } do
      assert RuleEngine.evaluate(
               %{"fact" => "bogus_fact", "op" => "gte", "value" => 0},
               account.id
             )

      refute RuleEngine.evaluate(
               %{"fact" => "bogus_fact", "op" => "gte", "value" => 1},
               account.id
             )
    end

    test "a malformed leaf evaluates to false", %{account: account} do
      refute RuleEngine.evaluate(%{"nonsense" => true}, account.id)
    end
  end

  describe "evaluate/2 — combinators" do
    test "and requires every condition", %{account: account} do
      rule = %{
        "and" => [
          %{"fact" => "total_xp", "op" => "gte", "value" => 500},
          %{"fact" => "streak_weeks", "op" => "gte", "value" => 3}
        ]
      }

      assert RuleEngine.evaluate(rule, account.id)

      failing_rule =
        put_in(
          rule["and"],
          rule["and"] ++ [%{"fact" => "total_xp", "op" => "gte", "value" => 9999}]
        )

      refute RuleEngine.evaluate(failing_rule, account.id)
    end

    test "or requires at least one condition", %{account: account} do
      rule = %{
        "or" => [
          %{"fact" => "total_xp", "op" => "gte", "value" => 9999},
          %{"fact" => "streak_weeks", "op" => "gte", "value" => 3}
        ]
      }

      assert RuleEngine.evaluate(rule, account.id)
    end

    test "not inverts a condition", %{account: account} do
      rule = %{"not" => %{"fact" => "total_xp", "op" => "gte", "value" => 9999}}
      assert RuleEngine.evaluate(rule, account.id)
    end

    test "combinators nest arbitrarily deep", %{account: account} do
      rule = %{
        "and" => [
          %{
            "or" => [
              %{"fact" => "total_xp", "op" => "gte", "value" => 9999},
              %{"fact" => "streak_weeks", "op" => "gte", "value" => 1}
            ]
          },
          %{"not" => %{"fact" => "streak_weeks", "op" => "gte", "value" => 100}}
        ]
      }

      assert RuleEngine.evaluate(rule, account.id)
    end
  end

  describe "validate/1" do
    test "accepts a well-formed leaf" do
      assert :ok = RuleEngine.validate(%{"fact" => "total_xp", "op" => "gte", "value" => 100})
    end

    test "accepts a leaf with args" do
      assert :ok =
               RuleEngine.validate(%{
                 "fact" => "accepted_submissions_count",
                 "args" => %{"block_type" => "code"},
                 "op" => "gte",
                 "value" => 10
               })
    end

    test "rejects an unknown fact" do
      assert {:error, _} = RuleEngine.validate(%{"fact" => "bogus", "op" => "gte", "value" => 1})
    end

    test "rejects an unknown operator" do
      assert {:error, _} =
               RuleEngine.validate(%{"fact" => "total_xp", "op" => "wat", "value" => 1})
    end

    test "rejects an empty and/or list" do
      assert {:error, _} = RuleEngine.validate(%{"and" => []})
      assert {:error, _} = RuleEngine.validate(%{"or" => []})
    end

    test "rejects a non-map not" do
      assert {:error, _} = RuleEngine.validate(%{"not" => [1, 2]})
    end

    test "validates recursively inside and/or" do
      assert {:error, _} =
               RuleEngine.validate(%{
                 "and" => [
                   %{"fact" => "total_xp", "op" => "gte", "value" => 1},
                   %{"fact" => "bogus", "op" => "gte", "value" => 1}
                 ]
               })
    end

    test "rejects a completely malformed rule" do
      assert {:error, _} = RuleEngine.validate(%{"whatever" => 1})
      assert {:error, _} = RuleEngine.validate("not even a map")
    end
  end
end
