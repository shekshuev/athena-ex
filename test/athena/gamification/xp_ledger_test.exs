defmodule Athena.Gamification.XpLedgerTest do
  use Athena.DataCase, async: true

  alias Athena.Gamification.{XpLedger, XpEvent, AccountStats}
  alias Athena.Repo
  import Athena.Factory

  # Seeded by the create_gamification_xp_tables migration.
  @code_xp 15
  @quiz_exam_xp 40

  describe "record_activity/1" do
    test "awards XP for a block type with a non-zero base amount" do
      account = insert(:account)
      block = insert(:block, type: :code)

      assert {:ok, :awarded} =
               XpLedger.record_activity(%{
                 account_id: account.id,
                 block_id: block.id,
                 block_type: :code
               })

      assert XpLedger.total_xp(account.id) == @code_xp
      assert Repo.get_by(XpEvent, account_id: account.id, source_id: block.id).amount == @code_xp
    end

    test "does not award XP for a passive block type (base amount 0)" do
      account = insert(:account)
      block = insert(:block, type: :text)

      assert {:ok, :skipped} =
               XpLedger.record_activity(%{
                 account_id: account.id,
                 block_id: block.id,
                 block_type: :text
               })

      assert XpLedger.total_xp(account.id) == 0
      refute Repo.get_by(XpEvent, account_id: account.id, source_id: block.id)
    end

    test "does not award XP twice for the same (account, block) pair" do
      account = insert(:account)
      block = insert(:block, type: :code)
      payload = %{account_id: account.id, block_id: block.id, block_type: :code}

      assert {:ok, :awarded} = XpLedger.record_activity(payload)
      assert {:ok, :skipped} = XpLedger.record_activity(payload)

      assert XpLedger.total_xp(account.id) == @code_xp
      assert Repo.aggregate(XpEvent, :count) == 1
    end

    test "accumulates XP across different blocks" do
      account = insert(:account)
      code_block = insert(:block, type: :code)
      exam_block = insert(:block, type: :quiz_exam)

      XpLedger.record_activity(%{
        account_id: account.id,
        block_id: code_block.id,
        block_type: :code
      })

      XpLedger.record_activity(%{
        account_id: account.id,
        block_id: exam_block.id,
        block_type: :quiz_exam
      })

      assert XpLedger.total_xp(account.id) == @code_xp + @quiz_exam_xp
    end

    test "tracks XP per account independently" do
      account_a = insert(:account)
      account_b = insert(:account)
      block = insert(:block, type: :code)

      XpLedger.record_activity(%{account_id: account_a.id, block_id: block.id, block_type: :code})

      assert XpLedger.total_xp(account_a.id) == @code_xp
      assert XpLedger.total_xp(account_b.id) == 0
    end

    test "returns :skipped when block_type is missing (unresolvable block)" do
      account = insert(:account)

      assert {:ok, :skipped} =
               XpLedger.record_activity(%{
                 account_id: account.id,
                 block_id: Ecto.UUID.generate(),
                 block_type: nil
               })
    end
  end

  describe "total_xp/1" do
    test "returns 0 for an account with no gamification activity" do
      account = insert(:account)
      assert XpLedger.total_xp(account.id) == 0
    end
  end

  describe "record_activity/1 — sprint multiplier" do
    test "multiplies the awarded XP by an active sprint's multiplier" do
      role = insert(:role, permissions: ["cohorts.update", "cohorts.read"])
      instructor = insert(:account, role: role)
      cohort = insert(:cohort)
      account = insert(:account)
      insert(:cohort_membership, account_id: account.id, cohort_id: cohort.id)

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Athena.Gamification.Sprints.create_sprint(instructor, %{
        "cohort_id" => cohort.id,
        "title" => "Push",
        "starts_at" => DateTime.add(now, -3600, :second),
        "ends_at" => DateTime.add(now, 3600, :second),
        "xp_multiplier" => "2"
      })

      block = insert(:block, type: :code)

      XpLedger.record_activity(%{account_id: account.id, block_id: block.id, block_type: :code})

      assert XpLedger.total_xp(account.id) == @code_xp * 2
    end
  end

  test "AccountStats is created lazily on first award" do
    account = insert(:account)
    block = insert(:block, type: :code)

    refute Repo.get_by(AccountStats, account_id: account.id)

    XpLedger.record_activity(%{account_id: account.id, block_id: block.id, block_type: :code})

    assert %AccountStats{total_xp: @code_xp} = Repo.get_by(AccountStats, account_id: account.id)
  end
end
