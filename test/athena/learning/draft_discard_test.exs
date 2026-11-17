defmodule Athena.Learning.DraftDiscardTest do
  use Athena.DataCase, async: true
  import Athena.Factory
  alias Athena.Learning.{DraftCache, Submission, Submissions}

  setup do
    user = insert(:account)
    course = insert(:course)
    insert(:enrollment, account_id: user.id, course_id: course.id)
    section = insert(:section, course: course)
    block = insert(:block, section: section, type: :code)
    %{user: user, course: course, block: block}
  end

  test "discard removes only the draft and cache, retains submitted work and progress", ctx do
    submitted =
      insert(:submission,
        account_id: ctx.user.id,
        block_id: ctx.block.id,
        status: :graded,
        score: 60
      )

    {:ok, draft} = Submissions.save_draft(ctx.user, ctx.block.id, %{"code" => "draft"})
    {:ok, progress} = Athena.Learning.mark_completed(ctx.user.id, ctx.block.id)
    old = DraftCache.revision(ctx.user.id, nil, ctx.block.id)
    assert {:ok, revision} = Submissions.discard_draft(ctx.user, ctx.block.id, nil, revision: old)
    assert revision != old
    assert Repo.get(Submission, draft.id) == nil
    assert Repo.get!(Submission, submitted.id).status == :graded
    assert Repo.get!(Submission, submitted.id).score == 60
    assert Repo.get!(Athena.Learning.BlockProgress, progress.id).status == :completed
    assert DraftCache.get_draft(ctx.user.id, nil, ctx.block.id) == nil
    assert Submissions.get_draft(ctx.user.id, ctx.block.id) == nil

    assert {:error, :stale_draft} =
             Submissions.save_draft(ctx.user, ctx.block.id, %{"code" => "late autosave"}, nil,
               revision: old
             )

    assert Submissions.get_draft(ctx.user.id, ctx.block.id) == nil

    assert {:ok, _} =
             Submissions.save_draft(ctx.user, ctx.block.id, %{"code" => "new edit"}, nil,
               revision: revision
             )
  end

  test "team discard is shared and broadcasts a reset; personal and other drafts survive", ctx do
    team = insert(:cohort, type: :team)
    teammate = insert(:account)

    for user <- [ctx.user, teammate],
        do: insert(:cohort_membership, cohort_id: team.id, account_id: user.id)

    insert(:enrollment, cohort_id: team.id, course_id: ctx.course.id)

    insert(:submission,
      account_id: teammate.id,
      cohort_id: team.id,
      block_id: ctx.block.id,
      status: :graded
    )

    {:ok, shared} = Submissions.save_draft(teammate, ctx.block.id, %{"code" => "team"}, team.id)
    {:ok, personal} = Submissions.save_draft(ctx.user, ctx.block.id, %{"code" => "personal"})
    :ok = DraftCache.subscribe_to_draft_updates(team.id, ctx.block.id)
    assert {:ok, revision} = Submissions.discard_draft(ctx.user, ctx.block.id, team.id)
    assert_receive {:draft_reset, %{block_id: block_id, revision: ^revision}}
    assert block_id == ctx.block.id
    assert Repo.get(Submission, shared.id) == nil
    assert Repo.get!(Submission, personal.id).status == :draft
    assert DraftCache.get_draft(teammate.id, team.id, ctx.block.id) == nil
  end

  test "requires a submission, enrollment and writable policy", ctx do
    {:ok, draft} = Submissions.save_draft(ctx.user, ctx.block.id, %{"code" => "draft"})
    assert {:error, :no_submission} = Submissions.discard_draft(ctx.user, ctx.block.id)
    insert(:submission, account_id: ctx.user.id, block_id: ctx.block.id, status: :graded)
    ctx.block |> Ecto.Changeset.change(interaction_mode: :readonly) |> Repo.update!()
    assert {:error, :forbidden} = Submissions.discard_draft(ctx.user, ctx.block.id)
    assert Repo.get!(Submission, draft.id).status == :draft
  end

  test "does not remove a draft while its code job is queued or running", ctx do
    insert(:submission, account_id: ctx.user.id, block_id: ctx.block.id, status: :graded)
    {:ok, draft} = Submissions.save_draft(ctx.user, ctx.block.id, %{"code" => "draft"})
    %{submission_id: draft.id} |> Athena.Execution.TestWorker.new() |> Oban.insert!()
    assert {:error, :processing} = Submissions.discard_draft(ctx.user, ctx.block.id)
    assert Repo.get!(Submission, draft.id).status == :draft
  end
end
