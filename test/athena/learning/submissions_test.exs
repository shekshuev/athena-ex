defmodule Athena.Learning.SubmissionsTest do
  use Athena.DataCase, async: true

  alias Athena.Learning.Submissions
  alias Athena.Learning.Submission
  import Athena.Factory

  describe "list_submissions/1" do
    test "returns paginated submissions with default sorting (inserted_at desc)" do
      sub1 = insert(:submission, inserted_at: ~U[2026-01-01 10:00:00Z])
      sub2 = insert(:submission, inserted_at: ~U[2026-01-02 10:00:00Z])

      assert {:ok, {submissions, meta}} = Submissions.list_submissions(%{})

      assert length(submissions) == 2
      assert Enum.at(submissions, 0).id == sub2.id
      assert Enum.at(submissions, 1).id == sub1.id
      assert meta.total_count == 2
    end

    test "filters submissions by status" do
      insert(:submission, status: :graded)
      insert(:submission, status: :graded)
      sub_review = insert(:submission, status: :needs_review)

      params = %{
        "filters" => [
          %{"field" => "status", "op" => "==", "value" => "needs_review"}
        ]
      }

      assert {:ok, {submissions, meta}} = Submissions.list_submissions(params)

      assert length(submissions) == 1
      assert hd(submissions).id == sub_review.id
      assert meta.total_count == 1
    end

    test "sorts submissions by score" do
      sub1 = insert(:submission, score: 100)
      sub2 = insert(:submission, score: 10)

      params = %{
        "order_by" => ["score"],
        "order_directions" => ["asc"]
      }

      assert {:ok, {submissions, _meta}} = Submissions.list_submissions(params)

      assert Enum.map(submissions, & &1.id) == [sub2.id, sub1.id]
    end
  end

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

  describe "get_latest_submissions/2" do
    test "returns a map of the latest submissions for the given block ids" do
      account_id = Ecto.UUID.generate()
      other_account_id = Ecto.UUID.generate()

      block_1_id = Ecto.UUID.generate()
      block_2_id = Ecto.UUID.generate()
      block_3_id = Ecto.UUID.generate()

      now = DateTime.utc_now() |> DateTime.truncate(:second)
      yesterday = DateTime.add(now, -1, :day)
      last_week = DateTime.add(now, -7, :day)

      insert(:submission,
        account_id: account_id,
        block_id: block_1_id,
        score: 10,
        inserted_at: last_week
      )

      insert(:submission,
        account_id: account_id,
        block_id: block_1_id,
        score: 20,
        inserted_at: yesterday
      )

      latest_b1 =
        insert(:submission,
          account_id: account_id,
          block_id: block_1_id,
          score: 50,
          inserted_at: now
        )

      latest_b2 =
        insert(:submission,
          account_id: account_id,
          block_id: block_2_id,
          score: 100,
          inserted_at: yesterday
        )

      insert(:submission,
        account_id: account_id,
        block_id: block_2_id,
        score: 0,
        inserted_at: last_week
      )

      insert(:submission,
        account_id: other_account_id,
        block_id: block_1_id,
        score: 99,
        inserted_at: now
      )

      block_ids = [block_1_id, block_2_id, block_3_id]
      result = Submissions.get_latest_submissions(account_id, block_ids)

      assert map_size(result) == 2

      assert result[block_1_id].id == latest_b1.id
      assert result[block_1_id].score == 50

      assert result[block_2_id].id == latest_b2.id
      assert result[block_2_id].score == 100

      refute Map.has_key?(result, block_3_id)
    end

    test "returns an empty map if no submissions exist for the given blocks" do
      account_id = Ecto.UUID.generate()
      block_ids = [Ecto.UUID.generate(), Ecto.UUID.generate()]

      assert %{} == Submissions.get_latest_submissions(account_id, block_ids)
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
