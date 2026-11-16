defmodule Athena.Learning.SubmissionPerfectScoreTest do
  use Athena.DataCase, async: true

  import Athena.Factory

  alias Athena.Learning.{DraftCache, Submission, Submissions}

  setup do
    user = insert(:account)
    block = insert(:block, type: :code, content: %{"language" => "sql"})
    attrs = %{"block_id" => block.id, "content" => %{"type" => "code", "code" => "SELECT 2"}}
    %{user: user, block: block, attrs: attrs}
  end

  test "rejects another attempt after a graded or accepted perfect score", ctx do
    for status <- [:graded, :accepted] do
      perfect =
        insert(:submission,
          account_id: ctx.user.id,
          block_id: ctx.block.id,
          status: status,
          score: 100
        )

      assert_already_solved(Submissions.create_submission(ctx.user, ctx.attrs))
      assert Repo.aggregate(Submission, :count) == 1
      assert all_enqueued(worker: Athena.Execution.Worker) == []

      Repo.delete!(perfect)
    end
  end

  test "an older perfect attempt still blocks submissions after a later lower score", ctx do
    insert(:submission,
      account_id: ctx.user.id,
      block_id: ctx.block.id,
      status: :graded,
      score: 100,
      inserted_at: ~U[2026-01-01 10:00:00Z]
    )

    insert(:submission,
      account_id: ctx.user.id,
      block_id: ctx.block.id,
      status: :graded,
      score: 40,
      inserted_at: ~U[2026-01-01 11:00:00Z]
    )

    assert_already_solved(Submissions.create_submission(ctx.user, ctx.attrs))
    assert Repo.aggregate(Submission, :count) == 2
  end

  test "rejection preserves the existing draft and its cache", ctx do
    content = %{"type" => "code", "code" => "SELECT 'draft'"}
    {:ok, draft} = Submissions.save_draft(ctx.user, ctx.block.id, content)

    insert(:submission,
      account_id: ctx.user.id,
      block_id: ctx.block.id,
      status: :graded,
      score: 100
    )

    assert_already_solved(Submissions.create_submission(ctx.user, ctx.attrs))
    assert %{status: :draft, content: ^content} = Repo.get!(Submission, draft.id)
    assert DraftCache.get_draft(ctx.user.id, nil, ctx.block.id) == content
    assert all_enqueued(worker: Athena.Execution.Worker) == []
  end

  test "a teammate's perfect score blocks the shared team attempt", ctx do
    team = insert(:cohort, type: :team)
    teammate = insert(:account)

    insert(:submission,
      account_id: teammate.id,
      cohort_id: team.id,
      block_id: ctx.block.id,
      status: :graded,
      score: 100
    )

    attrs = Map.put(ctx.attrs, "cohort_id", team.id)
    assert_already_solved(Submissions.create_submission(ctx.user, attrs))
    assert Repo.aggregate(Submission, :count) == 1
    assert all_enqueued(worker: Athena.Execution.Worker) == []
  end

  test "other users, blocks and teams do not prevent an individual submission", ctx do
    other = insert(:account)
    team = insert(:cohort, type: :team)
    other_block = insert(:block)

    for attrs <- [
          [account_id: other.id, block_id: ctx.block.id],
          [account_id: ctx.user.id, block_id: other_block.id],
          [account_id: ctx.user.id, block_id: ctx.block.id, cohort_id: team.id]
        ] do
      insert(:submission, Keyword.merge([status: :graded, score: 100], attrs))
    end

    assert {:ok, %{status: :pending}} = Submissions.create_submission(ctx.user, ctx.attrs)
  end

  test "personal and other-team perfect scores do not block the target team", ctx do
    target = insert(:cohort, type: :team)
    other = insert(:cohort, type: :team)

    for cohort_id <- [nil, other.id] do
      insert(:submission,
        account_id: ctx.user.id,
        cohort_id: cohort_id,
        block_id: ctx.block.id,
        status: :graded,
        score: 100
      )
    end

    assert {:ok, %{cohort_id: team_id}} =
             Submissions.create_submission(ctx.user, Map.put(ctx.attrs, "cohort_id", target.id))

    assert team_id == target.id
  end

  test "an incomplete, rejected, test-run or child result is not a completed perfect attempt",
       ctx do
    parent = insert(:submission, account_id: ctx.user.id)

    for status <- [:draft, :pending, :processing, :needs_review, :rejected] do
      insert(:submission,
        account_id: ctx.user.id,
        block_id: ctx.block.id,
        status: status,
        score: 100
      )
    end

    insert(:submission,
      account_id: ctx.user.id,
      block_id: ctx.block.id,
      status: :graded,
      score: 100,
      content: %{"is_test_run" => true}
    )

    insert(:submission,
      account_id: ctx.user.id,
      block_id: ctx.block.id,
      parent_submission_id: parent.id,
      status: :graded,
      score: 100
    )

    assert {:ok, %{status: :pending}} = Submissions.create_submission(ctx.user, ctx.attrs)
  end

  test "a grade below 100 still permits the next attempt", ctx do
    insert(:submission,
      account_id: ctx.user.id,
      block_id: ctx.block.id,
      status: :graded,
      score: 99
    )

    assert {:ok, %{status: :pending}} = Submissions.create_submission(ctx.user, ctx.attrs)
  end

  defp assert_already_solved({:error, %Ecto.Changeset{} = changeset}) do
    refute changeset.valid?
    assert {_message, [validation: :already_solved]} = Keyword.fetch!(changeset.errors, :base)
  end
end
