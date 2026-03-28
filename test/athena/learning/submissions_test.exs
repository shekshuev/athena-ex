defmodule Athena.Learning.SubmissionsTest do
  use Athena.DataCase, async: true

  alias Athena.Learning.Submissions
  alias Athena.Learning.Submission
  import Athena.Factory

  describe "get_submission/2" do
    test "returns the latest submission for a given account and block" do
      account_id = Ecto.UUID.generate()
      block_id = Ecto.UUID.generate()

      insert(:submission,
        account_id: account_id,
        block_id: block_id,
        score: 10,
        inserted_at: DateTime.add(DateTime.utc_now(), -2, :day)
      )

      latest =
        insert(:submission,
          account_id: account_id,
          block_id: block_id,
          score: 100,
          inserted_at: DateTime.utc_now()
        )

      fetched = Submissions.get_submission(account_id, block_id)

      assert fetched.id == latest.id
      assert fetched.score == 100
    end

    test "returns nil if no submission exists" do
      assert nil == Submissions.get_submission(Ecto.UUID.generate(), Ecto.UUID.generate())
    end
  end

  describe "create_submission/1" do
    test "creates a submission with valid attributes" do
      account_id = Ecto.UUID.generate()
      block_id = Ecto.UUID.generate()

      attrs = %{
        "account_id" => account_id,
        "block_id" => block_id,
        "content" => %{"flag" => "athena{1337}"},
        "status" => "pending"
      }

      assert {:ok, %Submission{} = submission} = Submissions.create_submission(attrs)
      assert submission.account_id == account_id
      assert submission.block_id == block_id
      assert submission.content["flag"] == "athena{1337}"
      assert submission.status == :pending
      assert submission.score == 0
    end

    test "returns error changeset with missing required attributes" do
      assert {:error, changeset} = Submissions.create_submission(%{})
      assert "can't be blank" in errors_on(changeset).account_id
      assert "can't be blank" in errors_on(changeset).block_id
    end
  end

  describe "update_submission/2" do
    test "updates submission attributes" do
      submission = insert(:submission, status: :pending, score: 0)

      assert {:ok, updated} =
               Submissions.update_submission(submission, %{
                 "status" => "graded",
                 "score" => 100,
                 "feedback" => "Good job!"
               })

      assert updated.status == :graded
      assert updated.score == 100
      assert updated.feedback == "Good job!"
    end
  end
end
