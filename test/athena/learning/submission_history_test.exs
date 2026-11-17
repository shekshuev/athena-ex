defmodule Athena.Learning.SubmissionHistoryTest do
  use Athena.DataCase, async: true
  import Athena.Factory
  alias Athena.Learning.Submissions
  alias Athena.Content.ScoringRules

  test "latest code and feedback follow submission time, not score or review time" do
    user = insert(:account)
    block = insert(:block)

    old =
      insert(:submission,
        account_id: user.id,
        block_id: block.id,
        status: :graded,
        score: 90,
        feedback: "Old",
        inserted_at: ~U[2026-01-01 10:00:00Z],
        updated_at: ~U[2026-01-03 10:00:00Z]
      )

    latest =
      insert(:submission,
        account_id: user.id,
        block_id: block.id,
        status: :graded,
        score: 40,
        feedback: "Latest",
        inserted_at: ~U[2026-01-02 10:00:00Z]
      )

    insert(:submission, account_id: user.id, block_id: block.id, status: :draft, score: 100)
    assert Submissions.get_latest_submissions(user.id, [block.id])[block.id].id == latest.id
    assert Submissions.get_feedback_map(user.id, [block.id])[block.id].feedback == "Latest"
    {:ok, _} = Submissions.system_update_submission(old, %{feedback: "Reviewed again"})
    assert Submissions.get_latest_submissions(user.id, [block.id])[block.id].id == latest.id
  end

  test "ties have a stable id order; new pending attempts do not fall back to old feedback" do
    user = insert(:account)
    block = insert(:block)
    time = ~U[2026-01-01 10:00:00Z]

    insert(:submission,
      id: "00000000-0000-0000-0000-000000000001",
      account_id: user.id,
      block_id: block.id,
      status: :graded,
      score: 90,
      feedback: "Old",
      inserted_at: time
    )

    latest =
      insert(:submission,
        id: "00000000-0000-0000-0000-000000000002",
        account_id: user.id,
        block_id: block.id,
        status: :pending,
        score: 0,
        inserted_at: time
      )

    assert Submissions.get_latest_submissions(user.id, [block.id])[block.id].id == latest.id
    assert Submissions.get_feedback_map(user.id, [block.id]) == %{}
  end

  test "an old rejection restricts sending without replacing the latest shown attempt" do
    user = insert(:account)
    block = insert(:block)

    insert(:submission,
      account_id: user.id,
      block_id: block.id,
      status: :rejected,
      inserted_at: ~U[2026-01-01 10:00:00Z]
    )

    latest =
      insert(:submission,
        account_id: user.id,
        block_id: block.id,
        status: :graded,
        score: 40,
        inserted_at: ~U[2026-01-02 10:00:00Z]
      )

    assert Submissions.get_latest_submissions(user.id, [block.id])[block.id].id == latest.id
    assert Submissions.submission_locks(user.id, [block.id]) == %{block.id => :rejected}
    assert {:error, changeset} = Submissions.create_submission(user, %{"block_id" => block.id})
    assert {_, validation: :submission_rejected} = Keyword.fetch!(changeset.errors, :base)
  end

  test "ranking uses the last real attempt; drafts and test runs do not affect scores or counts" do
    course = insert(:course, type: :competition)
    section = insert(:section, course: course)
    block = insert(:block, section: section)
    team = insert(:cohort, type: :team)
    user = insert(:account)
    insert(:enrollment, cohort_id: team.id, course_id: course.id)

    insert(:submission,
      account_id: user.id,
      cohort_id: team.id,
      block_id: block.id,
      status: :graded,
      score: 80,
      inserted_at: ~U[2026-01-01 10:00:00Z]
    )

    latest =
      insert(:submission,
        account_id: user.id,
        cohort_id: team.id,
        block_id: block.id,
        status: :graded,
        score: 40,
        inserted_at: ~U[2026-01-02 10:00:00Z]
      )

    insert(:submission,
      account_id: user.id,
      cohort_id: team.id,
      block_id: block.id,
      status: :draft,
      score: 100
    )

    insert(:submission,
      account_id: user.id,
      cohort_id: team.id,
      block_id: block.id,
      status: :graded,
      score: 100,
      content: %{"is_test_run" => true}
    )

    assert [%{total_score: 40, attempts: 2}] = Submissions.get_team_leaderboard(course.id)

    {:ok, latest} =
      Submissions.system_update_submission(latest, %{status: :processing, score: 100})

    assert [%{total_score: 0, first_bloods: 0, attempts: 2}] =
             Submissions.get_team_leaderboard(course.id, %ScoringRules{solve_threshold: 0})

    {:ok, _} = Submissions.system_update_submission(latest, %{status: :graded, score: 60})
    assert [%{total_score: 60}] = Submissions.get_team_leaderboard(course.id)
  end
end
