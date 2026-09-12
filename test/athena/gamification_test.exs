defmodule Athena.GamificationTest do
  use Athena.DataCase, async: true

  alias Athena.Gamification
  import Athena.Factory

  describe "level_for_xp/1" do
    test "starts at level 1 with a floor of 0" do
      assert Gamification.level_for_xp(0) == %{level: 1, floor: 0, ceiling: 100}
    end

    test "stays at the current level just below the next threshold" do
      assert Gamification.level_for_xp(99) == %{level: 1, floor: 0, ceiling: 100}
    end

    test "advances exactly at a threshold" do
      assert Gamification.level_for_xp(100) == %{level: 2, floor: 100, ceiling: 250}
    end

    test "has no ceiling past the top of the ladder" do
      assert Gamification.level_for_xp(1_000_000) == %{level: 10, floor: 32_000, ceiling: nil}
    end
  end

  describe "total_xp/1" do
    test "delegates to the XP ledger" do
      account = insert(:account)
      assert Gamification.total_xp(account.id) == 0
    end
  end
end
