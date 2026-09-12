defmodule Athena.Gamification.FactsTest do
  use Athena.DataCase, async: true

  alias Athena.Gamification.Facts
  import Athena.Factory

  describe "value/3 — account stats facts" do
    test "returns 0 for an account with no gamification activity" do
      account = insert(:account)

      assert Facts.value("total_xp", %{}, account.id) == 0
      assert Facts.value("streak_weeks", %{}, account.id) == 0
      assert Facts.value("current_combo", %{}, account.id) == 0
    end

    test "reads from AccountStats when present" do
      account = insert(:account)

      insert(:account_stats,
        account_id: account.id,
        total_xp: 250,
        current_streak_weeks: 4,
        current_combo: 6
      )

      assert Facts.value("total_xp", %{}, account.id) == 250
      assert Facts.value("streak_weeks", %{}, account.id) == 4
      assert Facts.value("current_combo", %{}, account.id) == 6
    end
  end

  describe "value/3 — weekly_xp" do
    test "sums only this week's XP events" do
      account = insert(:account)
      week_start = Date.beginning_of_week(Date.utc_today())

      insert(:xp_event, account_id: account.id, amount: 15, source_id: Ecto.UUID.generate())

      insert(:xp_event,
        account_id: account.id,
        amount: 40,
        source_id: Ecto.UUID.generate(),
        inserted_at: DateTime.new!(Date.add(week_start, -7), ~T[12:00:00], "Etc/UTC")
      )

      assert Facts.value("weekly_xp", %{}, account.id) == 15
    end

    test "returns 0 with no events this week" do
      account = insert(:account)
      assert Facts.value("weekly_xp", %{}, account.id) == 0
    end
  end

  describe "value/3 — accepted_submissions_count" do
    test "counts accepted top-level submissions, ignoring drafts and child (exam question) ones" do
      account = insert(:account)
      block = insert(:block, type: :code)

      insert(:submission, account_id: account.id, block_id: block.id, status: :accepted)
      insert(:submission, account_id: account.id, block_id: block.id, status: :draft)

      parent = insert(:submission, account_id: account.id, status: :accepted)

      insert(:submission,
        account_id: account.id,
        status: :accepted,
        parent_submission_id: parent.id
      )

      assert Facts.value("accepted_submissions_count", %{}, account.id) == 2
    end

    test "filters by block_type when given as an arg" do
      account = insert(:account)
      code_block = insert(:block, type: :code)
      quiz_block = insert(:block, type: :quiz_question)

      insert(:submission, account_id: account.id, block_id: code_block.id, status: :accepted)
      insert(:submission, account_id: account.id, block_id: quiz_block.id, status: :accepted)

      assert Facts.value(
               "accepted_submissions_count",
               %{"block_type" => :code},
               account.id
             ) == 1
    end
  end

  describe "value/3 — first_try_accept_count" do
    test "counts blocks accepted on the very first attempt" do
      account = insert(:account)
      block = insert(:block, type: :code)

      insert(:submission,
        account_id: account.id,
        block_id: block.id,
        status: :accepted,
        inserted_at: ~U[2026-01-01 10:00:00Z]
      )

      assert Facts.value("first_try_accept_count", %{}, account.id) == 1
    end

    test "does not count a block that failed before succeeding" do
      account = insert(:account)
      block = insert(:block, type: :code)

      insert(:submission,
        account_id: account.id,
        block_id: block.id,
        status: :wrong_answer,
        inserted_at: ~U[2026-01-01 10:00:00Z]
      )

      insert(:submission,
        account_id: account.id,
        block_id: block.id,
        status: :accepted,
        inserted_at: ~U[2026-01-01 10:05:00Z]
      )

      assert Facts.value("first_try_accept_count", %{}, account.id) == 0
    end
  end

  describe "value/3 — unknown fact" do
    test "returns 0 without raising" do
      account = insert(:account)
      assert Facts.value("something_made_up", %{}, account.id) == 0
    end
  end

  describe "known_facts/0" do
    test "lists the fixed catalog of measurable facts" do
      assert "total_xp" in Facts.known_facts()
      assert "accepted_submissions_count" in Facts.known_facts()
    end
  end
end
