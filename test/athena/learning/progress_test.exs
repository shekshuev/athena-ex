defmodule Athena.Learning.ProgressTest do
  use Athena.DataCase, async: true

  alias Athena.Learning.Progress
  alias Athena.Learning.{BlockProgress, CourseProgressCache}
  alias Athena.Content.CompletionRule
  alias Athena.Repo
  import Athena.Factory

  setup do
    user = insert(:account)
    team = insert(:cohort, type: :team)
    %{user: user, team: team}
  end

  describe "mark_completed/3" do
    test "records individual block progress (UPSERT)", %{user: user} do
      block = insert(:block)

      assert {:ok, %BlockProgress{} = progress} = Progress.mark_completed(user.id, block.id)
      assert progress.account_id == user.id
      assert progress.block_id == block.id
      assert progress.status == :completed
      assert progress.cohort_id == nil

      assert {:ok, %BlockProgress{}} = Progress.mark_completed(user.id, block.id)
    end

    test "records team block progress (UPSERT with partial index)", %{user: user, team: team} do
      block = insert(:block)

      assert {:ok, %BlockProgress{} = progress} =
               Progress.mark_completed(user.id, block.id, team.id)

      assert progress.account_id == user.id
      assert progress.block_id == block.id
      assert progress.cohort_id == team.id
      assert {:ok, %BlockProgress{}} = Progress.mark_completed(user.id, block.id, team.id)
    end
  end

  describe "revoke_completed/4" do
    test "removes individual block progress without affecting team progress", %{
      user: user,
      team: team
    } do
      section = insert(:section)
      block = insert(:block, section: section)

      Progress.mark_completed(user.id, block.id)
      Progress.mark_completed(user.id, block.id, team.id)

      assert block.id in Progress.completed_block_ids(user.id, section.id)
      assert block.id in Progress.completed_block_ids(user.id, section.id, team.id)

      assert {1, nil} = Progress.revoke_completed(Repo, user.id, block.id)

      refute block.id in Progress.completed_block_ids(user.id, section.id)
      assert block.id in Progress.completed_block_ids(user.id, section.id, team.id)
    end

    test "removes team block progress without affecting individual progress", %{
      user: user,
      team: team
    } do
      section = insert(:section)
      block = insert(:block, section: section)

      Progress.mark_completed(user.id, block.id)
      Progress.mark_completed(user.id, block.id, team.id)

      assert {1, nil} = Progress.revoke_completed(Repo, user.id, block.id, team.id)

      refute block.id in Progress.completed_block_ids(user.id, section.id, team.id)
      assert block.id in Progress.completed_block_ids(user.id, section.id)
    end
  end

  describe "completed_block_ids/3" do
    test "fetches only individual completions, ignoring team ones", %{user: user, team: team} do
      section = insert(:section)
      block1 = insert(:block, section: section)
      block2 = insert(:block, section: section)

      Progress.mark_completed(user.id, block1.id)
      Progress.mark_completed(user.id, block2.id, team.id)

      ids = Progress.completed_block_ids(user.id, section.id)
      assert block1.id in ids
      refute block2.id in ids
    end

    test "fetches only team completions, ignoring individual ones", %{user: user, team: team} do
      section = insert(:section)
      block1 = insert(:block, section: section)
      block2 = insert(:block, section: section)

      Progress.mark_completed(user.id, block1.id)
      Progress.mark_completed(user.id, block2.id, team.id)

      ids = Progress.completed_block_ids(user.id, section.id, team.id)
      refute block1.id in ids
      assert block2.id in ids
    end
  end

  describe "accessible_section_ids/5 (Retrograde Locking)" do
    test "grants access to everything if there are no gates", %{user: user} do
      course = insert(:course)
      s1 = insert(:section, course: course)
      s2 = insert(:section, course: course)

      insert(:block, section: s1)

      accessible = Progress.accessible_section_ids(user, course.id, [s1, s2])
      assert s1.id in accessible
      assert s2.id in accessible
    end

    test "halts access at the first section with an uncompleted gate", %{user: user} do
      course = insert(:course)
      s1 = insert(:section, course: course)
      s2 = insert(:section, course: course)
      s3 = insert(:section, course: course)

      gate_block = insert(:block, section: s2, completion_rule: %CompletionRule{type: :button})

      accessible = Progress.accessible_section_ids(user, course.id, [s1, s2, s3])
      assert s1.id in accessible
      assert s2.id in accessible
      refute s3.id in accessible

      Progress.mark_completed(user.id, gate_block.id)

      new_accessible = Progress.accessible_section_ids(user, course.id, [s1, s2, s3])
      assert s3.id in new_accessible
    end

    test "respects team progress for gates on competitions", %{user: user, team: team} do
      course = insert(:course, type: :competition)
      s1 = insert(:section, course: course)
      s2 = insert(:section, course: course)

      gate_block = insert(:block, section: s1, completion_rule: %CompletionRule{type: :submit})

      Progress.mark_completed(user.id, gate_block.id)

      accessible = Progress.accessible_section_ids(user, course.id, [s1, s2], [], team.id)
      assert s1.id in accessible
      refute s2.id in accessible

      Progress.mark_completed(user.id, gate_block.id, team.id)

      new_accessible = Progress.accessible_section_ids(user, course.id, [s1, s2], [], team.id)
      assert s2.id in new_accessible
    end

    test "ignores hidden blocks even if they have completion rules (gates)", %{user: user} do
      course = insert(:course)
      s1 = insert(:section, course: course)
      s2 = insert(:section, course: course)

      gate_visible = insert(:block, section: s1, completion_rule: %CompletionRule{type: :button})

      _gate_hidden =
        insert(:block,
          section: s2,
          visibility: :hidden,
          completion_rule: %CompletionRule{type: :submit}
        )

      s3 = insert(:section, course: course)

      accessible = Progress.accessible_section_ids(user, course.id, [s1, s2, s3])
      assert s1.id in accessible
      refute s2.id in accessible

      Progress.mark_completed(user.id, gate_visible.id)

      new_accessible = Progress.accessible_section_ids(user, course.id, [s1, s2, s3])
      assert s2.id in new_accessible
      assert s3.id in new_accessible
    end

    test "grants access to a section if it has reset_waterline: true, ignoring previous locked gates",
         %{user: user} do
      course = insert(:course)
      s1 = insert(:section, course: course)

      s2 =
        insert(:section,
          course: course,
          access_rules: %Athena.Content.AccessRules{reset_waterline: true}
        )

      s3 = insert(:section, course: course)

      insert(:block, section: s1, completion_rule: %CompletionRule{type: :button})

      accessible = Progress.accessible_section_ids(user, course.id, [s1, s2, s3])

      assert s1.id in accessible
      assert s2.id in accessible
      assert s3.id in accessible
    end
  end

  describe "mark_completed/3 broadcasts" do
    test "broadcasts a :block_completed fact with the resolved block type", %{user: user} do
      block = insert(:block, type: :code)
      Phoenix.PubSub.subscribe(Athena.PubSub, "learning_events")

      {:ok, _} = Progress.mark_completed(user.id, block.id)

      assert_receive {:block_completed,
                      %{
                        account_id: account_id,
                        block_id: block_id,
                        block_type: :code,
                        cohort_id: nil
                      }}

      assert account_id == user.id
      assert block_id == block.id
    end

    test "includes the cohort_id for team completions", %{user: user, team: team} do
      block = insert(:block, type: :code)
      Phoenix.PubSub.subscribe(Athena.PubSub, "learning_events")

      {:ok, _} = Progress.mark_completed(user.id, block.id, team.id)

      assert_receive {:block_completed, %{cohort_id: cohort_id}}
      assert cohort_id == team.id
    end
  end

  describe "last_activity/1" do
    test "returns nil when the account has no completions", %{user: user} do
      assert Progress.last_activity(user.id) == nil
    end

    test "returns the most recently completed block for the account", %{user: user} do
      older = insert(:block)
      newer = insert(:block)

      {:ok, older_progress} = Progress.mark_completed(user.id, older.id)

      stale_time = DateTime.add(DateTime.utc_now(), -60, :second) |> DateTime.truncate(:second)

      Repo.update_all(
        from(bp in BlockProgress, where: bp.id == ^older_progress.id),
        set: [updated_at: stale_time]
      )

      {:ok, _} = Progress.mark_completed(user.id, newer.id)

      assert %BlockProgress{block_id: block_id} = Progress.last_activity(user.id)
      assert block_id == newer.id
    end

    test "includes completions from any cohort the account belongs to", %{user: user, team: team} do
      block = insert(:block)
      insert(:cohort_membership, account_id: user.id, cohort_id: team.id)

      {:ok, _} = Progress.mark_completed(user.id, block.id, team.id)

      assert %BlockProgress{cohort_id: cohort_id} = Progress.last_activity(user.id)
      assert cohort_id == team.id
    end
  end

  describe "course_progress/3" do
    test "returns zero completion for a course with no activity", %{user: user} do
      course = insert(:course)
      section = insert(:section, course: course)
      insert(:block, section: section)
      insert(:block, section: section)

      assert Progress.course_progress(user.id, course.id) == %{
               completed: 0,
               total: 2,
               percent: 0
             }
    end

    test "computes the completion percentage from marked blocks", %{user: user} do
      course = insert(:course)
      section = insert(:section, course: course)
      block1 = insert(:block, section: section)
      block2 = insert(:block, section: section)

      {:ok, _} = Progress.mark_completed(user.id, block1.id)

      assert Progress.course_progress(user.id, course.id) == %{
               completed: 1,
               total: 2,
               percent: 50
             }

      {:ok, _} = Progress.mark_completed(user.id, block2.id)

      assert Progress.course_progress(user.id, course.id).percent == 100
    end

    test "returns zero total for a course without any blocks", %{user: user} do
      course = insert(:course)

      assert Progress.course_progress(user.id, course.id) == %{
               completed: 0,
               total: 0,
               percent: 0
             }
    end

    test "scopes completion to the given cohort", %{user: user, team: team} do
      course = insert(:course)
      section = insert(:section, course: course)
      block = insert(:block, section: section)
      insert(:cohort_membership, account_id: user.id, cohort_id: team.id)

      {:ok, _} = Progress.mark_completed(user.id, block.id, team.id)

      assert Progress.course_progress(user.id, course.id, team.id).percent == 100
      assert Progress.course_progress(user.id, course.id).percent == 0
    end

    test "within a team, progress is shared — any teammate's completion counts for everyone",
         %{user: user, team: team} do
      course = insert(:course)
      section = insert(:section, course: course)
      block1 = insert(:block, section: section)
      block2 = insert(:block, section: section)

      other_student = insert(:account)
      insert(:cohort_membership, account_id: user.id, cohort_id: team.id)
      insert(:cohort_membership, account_id: other_student.id, cohort_id: team.id)

      # `user` completes both blocks on the team's behalf — same collective
      # model Submissions.get_team_leaderboard/1 uses (one shared row per
      # (cohort_id, block_id), not per account).
      {:ok, _} = Progress.mark_completed(user.id, block1.id, team.id)
      {:ok, _} = Progress.mark_completed(user.id, block2.id, team.id)

      assert Progress.course_progress(user.id, course.id, team.id) == %{
               completed: 2,
               total: 2,
               percent: 100
             }

      # `other_student` never personally completed anything, but sees the
      # team's shared progress, not their own empty individual progress.
      assert Progress.course_progress(other_student.id, course.id, team.id) == %{
               completed: 2,
               total: 2,
               percent: 100
             }
    end
  end

  describe "CourseProgressCache (via mark_completed/3 and course_progress_batch/2)" do
    test "a fresh completion populates the cache, and re-submitting the same block does not double-count it",
         %{user: user} do
      course = insert(:course)
      section = insert(:section, course: course)
      block = insert(:block, section: section)
      insert(:block, section: section)

      Progress.mark_completed(user.id, block.id)
      Progress.mark_completed(user.id, block.id)

      row = Repo.get_by(CourseProgressCache, account_id: user.id, course_id: course.id)
      assert row.completed_count == 1
      assert row.total_count == 2
    end

    test "course_progress_batch/2 matches course_progress/3 for individual and team enrollments",
         %{user: user, team: team} do
      individual_course = insert(:course)
      section1 = insert(:section, course: individual_course)
      block1 = insert(:block, section: section1)
      Progress.mark_completed(user.id, block1.id)

      team_course = insert(:course)
      section2 = insert(:section, course: team_course)
      block2 = insert(:block, section: section2)
      insert(:block, section: section2)
      Progress.mark_completed(user.id, block2.id, team.id)

      individual_enrollment =
        insert(:enrollment, account_id: user.id, course_id: individual_course.id)
        |> Repo.preload(:cohort)

      team_enrollment =
        insert(:enrollment, cohort_id: team.id, course_id: team_course.id)
        |> Repo.preload(:cohort)

      result = Progress.course_progress_batch(user.id, [individual_enrollment, team_enrollment])

      assert result[individual_enrollment.id] ==
               Progress.course_progress(user.id, individual_course.id)

      assert result[team_enrollment.id] ==
               Progress.course_progress(user.id, team_course.id, team.id)

      assert result[individual_enrollment.id].percent == 100
      assert result[team_enrollment.id].percent == 50
    end

    test "course_progress_batch/2 falls back to a live computation for an enrollment with no cache row yet",
         %{user: user} do
      course = insert(:course)
      section = insert(:section, course: course)
      insert(:block, section: section)
      insert(:block, section: section)

      enrollment = insert(:enrollment, account_id: user.id, course_id: course.id)

      refute Repo.get_by(CourseProgressCache, account_id: user.id, course_id: course.id)

      result = Progress.course_progress_batch(user.id, [enrollment])

      assert result[enrollment.id] == %{completed: 0, total: 2, percent: 0}
    end
  end

  describe "block_solved?/2" do
    test "existing gates are unaffected: :submit always passes", %{user: user} do
      block =
        insert(:block, type: :file_assignment, completion_rule: %CompletionRule{type: :submit})

      submission = insert(:submission, account_id: user.id, block_id: block.id, status: :pending)

      assert Progress.block_solved?(block, submission)
    end

    test "existing gates are unaffected: :pass_auto_grade checks the score", %{user: user} do
      block =
        insert(:block,
          type: :quiz_question,
          completion_rule: %CompletionRule{type: :pass_auto_grade, min_score: 80}
        )

      passing = insert(:submission, account_id: user.id, block_id: block.id, score: 80)
      failing = insert(:submission, account_id: user.id, block_id: block.id, score: 79)

      assert Progress.block_solved?(block, passing)
      refute Progress.block_solved?(block, failing)
    end

    test "optional (:none) code block counts as solved when accepted", %{user: user} do
      block = insert(:block, type: :code, completion_rule: %CompletionRule{type: :none})
      accepted = insert(:submission, account_id: user.id, block_id: block.id, status: :accepted)
      wrong = insert(:submission, account_id: user.id, block_id: block.id, status: :wrong_answer)

      assert Progress.block_solved?(block, accepted)
      refute Progress.block_solved?(block, wrong)
    end

    test "optional (:none) quiz_question block requires a perfect score", %{user: user} do
      block = insert(:block, type: :quiz_question, completion_rule: %CompletionRule{type: :none})
      perfect = insert(:submission, account_id: user.id, block_id: block.id, score: 100)
      partial = insert(:submission, account_id: user.id, block_id: block.id, score: 90)

      assert Progress.block_solved?(block, perfect)
      refute Progress.block_solved?(block, partial)
    end

    test "optional (:none) file_assignment never counts — not auto-gradable", %{user: user} do
      block =
        insert(:block, type: :file_assignment, completion_rule: %CompletionRule{type: :none})

      submission =
        insert(:submission, account_id: user.id, block_id: block.id, status: :graded, score: 100)

      refute Progress.block_solved?(block, submission)
    end

    test "child exam-question submissions are excluded from the optional path", %{user: user} do
      block = insert(:block, type: :quiz_question, completion_rule: %CompletionRule{type: :none})
      parent = insert(:submission, account_id: user.id, block_id: block.id, status: :pending)

      child_submission =
        insert(:submission,
          account_id: user.id,
          block_id: block.id,
          score: 100,
          parent_submission_id: parent.id
        )

      refute Progress.block_solved?(block, child_submission)
    end
  end

  describe "maybe_complete_from_submission/1" do
    test "marks the block completed when it's now solved", %{user: user} do
      course = insert(:course)
      section = insert(:section, course: course)

      block =
        insert(:block,
          section: section,
          type: :code,
          completion_rule: %CompletionRule{type: :none}
        )

      submission = insert(:submission, account_id: user.id, block_id: block.id, status: :accepted)

      assert :ok = Progress.maybe_complete_from_submission(submission)

      assert Repo.get_by(BlockProgress,
               account_id: user.id,
               block_id: block.id,
               status: :completed
             )
    end

    test "does nothing when the block isn't solved", %{user: user} do
      course = insert(:course)
      section = insert(:section, course: course)

      block =
        insert(:block,
          section: section,
          type: :code,
          completion_rule: %CompletionRule{type: :none}
        )

      submission =
        insert(:submission, account_id: user.id, block_id: block.id, status: :wrong_answer)

      assert :ok = Progress.maybe_complete_from_submission(submission)

      refute Repo.get_by(BlockProgress, account_id: user.id, block_id: block.id)
    end

    test "is a no-op for child exam-question submissions", %{user: user} do
      course = insert(:course)
      section = insert(:section, course: course)
      block = insert(:block, section: section, type: :quiz_question)
      parent = insert(:submission, account_id: user.id, block_id: block.id, status: :pending)

      child_submission =
        insert(:submission,
          account_id: user.id,
          block_id: block.id,
          score: 100,
          parent_submission_id: parent.id
        )

      assert :ok = Progress.maybe_complete_from_submission(child_submission)

      refute Repo.get_by(BlockProgress, account_id: user.id, block_id: block.id)
    end

    test "is idempotent when called again after already completed", %{user: user} do
      course = insert(:course)
      section = insert(:section, course: course)

      block =
        insert(:block,
          section: section,
          type: :code,
          completion_rule: %CompletionRule{type: :none}
        )

      submission = insert(:submission, account_id: user.id, block_id: block.id, status: :accepted)

      Progress.maybe_complete_from_submission(submission)
      assert :ok = Progress.maybe_complete_from_submission(submission)

      assert Repo.aggregate(
               from(bp in BlockProgress,
                 where: bp.account_id == ^user.id and bp.block_id == ^block.id
               ),
               :count
             ) == 1
    end
  end
end
