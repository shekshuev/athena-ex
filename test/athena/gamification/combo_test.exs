defmodule Athena.Gamification.ComboTest do
  use Athena.DataCase, async: true

  alias Athena.Gamification.{Combo, AccountStats}
  alias Athena.Repo
  import Athena.Factory

  describe "record_result/1" do
    test "starts the combo at 1 on the first accepted submission" do
      account = insert(:account)
      submission = insert(:submission, account_id: account.id, status: :accepted)

      Combo.record_result(submission)

      assert Repo.get_by(AccountStats, account_id: account.id).current_combo == 1
    end

    test "increments the combo across consecutive accepted submissions" do
      account = insert(:account)

      Combo.record_result(insert(:submission, account_id: account.id, status: :accepted))
      Combo.record_result(insert(:submission, account_id: account.id, status: :accepted))
      Combo.record_result(insert(:submission, account_id: account.id, status: :accepted))

      assert Repo.get_by(AccountStats, account_id: account.id).current_combo == 3
    end

    test "a graded submission with score 100 counts as success" do
      account = insert(:account)

      submission = insert(:submission, account_id: account.id, status: :graded, score: 100)
      Combo.record_result(submission)

      assert Repo.get_by(AccountStats, account_id: account.id).current_combo == 1
    end

    test "a graded submission with score 0 breaks the combo" do
      account = insert(:account)

      Combo.record_result(insert(:submission, account_id: account.id, status: :accepted))
      Combo.record_result(insert(:submission, account_id: account.id, status: :graded, score: 0))

      assert Repo.get_by(AccountStats, account_id: account.id).current_combo == 0
    end

    test "a wrong_answer submission resets the combo to 0" do
      account = insert(:account)

      Combo.record_result(insert(:submission, account_id: account.id, status: :accepted))
      Combo.record_result(insert(:submission, account_id: account.id, status: :wrong_answer))

      assert Repo.get_by(AccountStats, account_id: account.id).current_combo == 0
    end

    test "non-terminal statuses (pending, processing, needs_review, draft) are ignored" do
      account = insert(:account)

      for status <- [:pending, :processing, :needs_review, :draft] do
        Combo.record_result(insert(:submission, account_id: account.id, status: status))
      end

      refute Repo.get_by(AccountStats, account_id: account.id)
    end

    test "child (exam question) submissions are ignored" do
      account = insert(:account)
      parent = insert(:submission, account_id: account.id, status: :accepted)

      child =
        insert(:submission,
          account_id: account.id,
          status: :accepted,
          parent_submission_id: parent.id
        )

      Combo.record_result(child)

      refute Repo.get_by(AccountStats, account_id: account.id)
    end
  end
end
