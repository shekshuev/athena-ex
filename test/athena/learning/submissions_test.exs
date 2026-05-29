defmodule Athena.Learning.SubmissionsTest do
  use Athena.DataCase, async: true

  alias Athena.Learning.{Submissions, Submission, DraftCache}
  import Athena.Factory

  describe "list_submissions/2" do
    setup do
      admin_role = insert(:role, permissions: ["grading.read"])
      admin = insert(:account, role: admin_role)
      %{admin: admin}
    end

    test "returns paginated submissions with default sorting (inserted_at desc)", %{admin: admin} do
      sub1 = insert(:submission, inserted_at: ~U[2026-01-01 10:00:00Z])
      sub2 = insert(:submission, inserted_at: ~U[2026-01-02 10:00:00Z])

      assert {:ok, {submissions, meta}} = Submissions.list_submissions(admin, %{})

      assert length(submissions) == 2
      assert Enum.at(submissions, 0).id == sub2.id
      assert Enum.at(submissions, 1).id == sub1.id
      assert meta.total_count == 2
    end

    test "filters submissions by status", %{admin: admin} do
      insert(:submission, status: :graded)
      insert(:submission, status: :graded)
      sub_review = insert(:submission, status: :needs_review)

      params = %{
        "filters" => [
          %{"field" => "status", "op" => "==", "value" => "needs_review"}
        ]
      }

      assert {:ok, {submissions, meta}} = Submissions.list_submissions(admin, params)

      assert length(submissions) == 1
      assert hd(submissions).id == sub_review.id
      assert meta.total_count == 1
    end

    test "sorts submissions by score", %{admin: admin} do
      sub1 = insert(:submission, score: 100)
      sub2 = insert(:submission, score: 10)

      params = %{
        "order_by" => ["score"],
        "order_directions" => ["asc"]
      }

      assert {:ok, {submissions, _meta}} = Submissions.list_submissions(admin, params)

      assert Enum.map(submissions, & &1.id) == [sub2.id, sub1.id]
    end
  end

  describe "get_submission!/2" do
    setup do
      admin_role = insert(:role, permissions: ["grading.read"])
      admin = insert(:account, role: admin_role)
      %{admin: admin}
    end

    test "returns the submission with given id", %{admin: admin} do
      submission = insert(:submission)
      assert Submissions.get_submission!(admin, submission.id).id == submission.id
    end

    test "raises Ecto.NoResultsError if submission does not exist", %{admin: admin} do
      assert_raise Ecto.NoResultsError, fn ->
        Submissions.get_submission!(admin, Ecto.UUID.generate())
      end
    end
  end

  describe "get_submission/3" do
    test "returns the latest individual submission for a given account and block (ignores team submissions)" do
      account_id = Ecto.UUID.generate()
      block_id = Ecto.UUID.generate()
      team = insert(:cohort)

      insert(:submission,
        account_id: account_id,
        block_id: block_id,
        cohort_id: team.id,
        score: 50,
        inserted_at: DateTime.utc_now()
      )

      insert(:submission,
        account_id: account_id,
        block_id: block_id,
        score: 10,
        inserted_at: DateTime.add(DateTime.utc_now(), -2, :day)
      )

      latest_individual =
        insert(:submission,
          account_id: account_id,
          block_id: block_id,
          score: 100,
          inserted_at: DateTime.utc_now()
        )

      fetched = Submissions.get_submission(account_id, block_id)

      assert fetched.id == latest_individual.id
      assert fetched.score == 100
      assert fetched.cohort_id == nil
    end

    test "returns the latest team submission when cohort_id is provided (ignores individual submissions)" do
      account_id = Ecto.UUID.generate()
      teammate_id = Ecto.UUID.generate()
      block_id = Ecto.UUID.generate()
      team = insert(:cohort)

      insert(:submission,
        account_id: account_id,
        block_id: block_id,
        score: 10,
        inserted_at: DateTime.utc_now()
      )

      team_sub =
        insert(:submission,
          account_id: teammate_id,
          block_id: block_id,
          cohort_id: team.id,
          score: 85,
          inserted_at: DateTime.utc_now()
        )

      fetched = Submissions.get_submission(account_id, block_id, team.id)

      assert fetched.id == team_sub.id
      assert fetched.score == 85
      assert fetched.cohort_id == team.id
    end

    test "returns nil if no submission exists" do
      assert nil == Submissions.get_submission(Ecto.UUID.generate(), Ecto.UUID.generate())
    end
  end

  describe "get_latest_submissions/3" do
    test "returns a map of the highest scored individual submissions for the given block ids" do
      account_id = Ecto.UUID.generate()
      other_account_id = Ecto.UUID.generate()
      _team = insert(:cohort)

      block_1_id = Ecto.UUID.generate()
      block_2_id = Ecto.UUID.generate()
      block_3_id = Ecto.UUID.generate()

      now = DateTime.utc_now() |> DateTime.truncate(:second)
      yesterday = DateTime.add(now, -1, :day)

      best_b1 =
        insert(:submission,
          account_id: account_id,
          block_id: block_1_id,
          score: 100,
          inserted_at: yesterday
        )

      insert(:submission,
        account_id: account_id,
        block_id: block_1_id,
        score: 0,
        inserted_at: now
      )

      best_b2 =
        insert(:submission,
          account_id: account_id,
          block_id: block_2_id,
          score: 80,
          inserted_at: yesterday
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

      assert result[block_1_id].id == best_b1.id
      assert result[block_1_id].score == 100

      assert result[block_2_id].id == best_b2.id
      assert result[block_2_id].score == 80

      refute Map.has_key?(result, block_3_id)
    end

    test "returns a map of the latest team submissions for the given block ids" do
      account_id = Ecto.UUID.generate()
      teammate_id = Ecto.UUID.generate()
      team = insert(:cohort)

      block_1_id = Ecto.UUID.generate()

      insert(:submission,
        account_id: account_id,
        block_id: block_1_id,
        score: 10,
        inserted_at: DateTime.utc_now()
      )

      team_sub =
        insert(:submission,
          account_id: teammate_id,
          block_id: block_1_id,
          cohort_id: team.id,
          score: 100,
          inserted_at: DateTime.utc_now()
        )

      result = Submissions.get_latest_submissions(account_id, [block_1_id], team.id)

      assert map_size(result) == 1
      assert result[block_1_id].id == team_sub.id
      assert result[block_1_id].cohort_id == team.id
    end

    test "returns an empty map if no submissions exist for the given blocks" do
      account_id = Ecto.UUID.generate()
      block_ids = [Ecto.UUID.generate(), Ecto.UUID.generate()]

      assert %{} == Submissions.get_latest_submissions(account_id, block_ids)
    end
  end

  describe "create_submission/2" do
    test "creates an individual submission, forcing account_id to prevent spoofing" do
      user = insert(:account)
      block = insert(:block)

      attrs = %{
        "account_id" => Ecto.UUID.generate(),
        "block_id" => block.id,
        "content" => %{"flag" => "athena{1337}"},
        "status" => "pending"
      }

      assert {:ok, %Submission{} = submission} = Submissions.create_submission(user, attrs)

      assert submission.account_id == user.id
      assert submission.block_id == block.id
    end

    test "creates a team submission when cohort_id is provided" do
      user = insert(:account)
      block = insert(:block)
      cohort = insert(:cohort, type: :team)

      attrs = %{
        "block_id" => block.id,
        "cohort_id" => cohort.id,
        "content" => %{"flag" => "team_flag{999}"},
        "status" => "pending"
      }

      assert {:ok, %Submission{} = submission} = Submissions.create_submission(user, attrs)
      assert submission.account_id == user.id
      assert submission.cohort_id == cohort.id
    end

    test "returns error changeset with missing required attributes" do
      user = insert(:account)
      assert {:error, changeset} = Submissions.create_submission(user, %{})
      assert "can't be blank" in errors_on(changeset).block_id
    end
  end

  describe "update_submission/3 and system_update_submission/2" do
    setup do
      admin_role = insert(:role, permissions: ["grading.update"])
      admin = insert(:account, role: admin_role)
      student = insert(:account, role: insert(:role, permissions: []))

      %{admin: admin, student: student}
    end

    test "system_update_submission/2 updates attributes without ACL (for Evaluator)" do
      submission = insert(:submission, status: :pending, score: 0)

      assert {:ok, updated} = Submissions.system_update_submission(submission, %{"score" => 100})
      assert updated.score == 100
    end

    test "update_submission/3 works if user has global grading.update permission", %{admin: admin} do
      submission = insert(:submission, status: :pending, score: 0)

      assert {:ok, updated} =
               Submissions.update_submission(admin, submission, %{
                 "feedback" => "Good job!",
                 "score" => 100,
                 "status" => "graded"
               })

      assert updated.score == 100
      assert updated.status == :graded
      assert updated.feedback == "Good job!"
    end

    test "update_submission/3 returns unauthorized if user lacks permission", %{student: student} do
      submission = insert(:submission)

      assert {:error, :unauthorized} =
               Submissions.update_submission(student, submission, %{"score" => 100})
    end
  end

  describe "ACL: own_only policy for update_submission/3" do
    setup do
      role =
        insert(:role,
          permissions: ["grading.update", "courses.read"],
          policies: %{
            "grading.update" => ["own_only"],
            "courses.read" => ["own_only"]
          }
        )

      instructor = insert(:account, role: role)
      student = insert(:account, role: insert(:role, permissions: []))

      %{instructor: instructor, student: student}
    end

    test "allows update if instructor owns the course", %{
      instructor: instructor,
      student: student
    } do
      course = insert(:course, owner_id: instructor.id)
      section = insert(:section, course: course)
      block = insert(:block, section: section)

      submission = insert(:submission, account_id: student.id, block_id: block.id, score: 0)

      assert {:ok, updated} =
               Submissions.update_submission(instructor, submission, %{"score" => 100})

      assert updated.score == 100
    end

    test "returns unauthorized if instructor does NOT own the course", %{
      instructor: instructor,
      student: student
    } do
      other_admin = insert(:account)
      course = insert(:course, owner_id: other_admin.id)
      section = insert(:section, course: course)
      block = insert(:block, section: section)

      submission = insert(:submission, account_id: student.id, block_id: block.id, score: 0)

      assert {:error, :unauthorized} =
               Submissions.update_submission(instructor, submission, %{"score" => 100})
    end
  end

  describe "get_team_leaderboard/1" do
    test "calculates team scores by summing max score per block and handles ties by time" do
      course = insert(:course)
      section = insert(:section, course: course)
      block1 = insert(:block, section: section)
      block2 = insert(:block, section: section)

      team1 = insert(:cohort, name: "Team Alpha", type: :team)
      team2 = insert(:cohort, name: "Team Beta", type: :team)
      team3 = insert(:cohort, name: "Team Gamma", type: :team)

      insert(:enrollment, course_id: course.id, cohort_id: team1.id)
      insert(:enrollment, course_id: course.id, cohort_id: team2.id)
      insert(:enrollment, course_id: course.id, cohort_id: team3.id)

      insert(:submission,
        block_id: block1.id,
        cohort_id: team1.id,
        score: 50,
        status: :graded,
        inserted_at: ~U[2026-01-01 09:00:00Z]
      )

      insert(:submission,
        block_id: block1.id,
        cohort_id: team1.id,
        score: 100,
        status: :graded,
        inserted_at: ~U[2026-01-01 10:00:00Z]
      )

      insert(:submission,
        block_id: block2.id,
        cohort_id: team1.id,
        score: 50,
        status: :graded,
        inserted_at: ~U[2026-01-01 12:00:00Z]
      )

      insert(:submission,
        block_id: block1.id,
        cohort_id: team2.id,
        score: 100,
        status: :graded,
        inserted_at: ~U[2026-01-02 10:00:00Z]
      )

      insert(:submission,
        block_id: block2.id,
        cohort_id: team2.id,
        score: 50,
        status: :graded,
        inserted_at: ~U[2026-01-02 12:00:00Z]
      )

      insert(:submission, block_id: block1.id, cohort_id: team3.id, score: 80, status: :graded)

      insert(:submission, block_id: block1.id, cohort_id: nil, score: 100, status: :graded)

      other_course_section = insert(:section)
      other_block = insert(:block, section: other_course_section)

      insert(:submission,
        block_id: other_block.id,
        cohort_id: team1.id,
        score: 100,
        status: :graded
      )

      leaderboard = Submissions.get_team_leaderboard(course.id)

      assert length(leaderboard) == 3

      [first, second, third] = leaderboard

      assert first.team_id == team1.id
      assert first.total_score == 150
      assert first.team_name == "Team Alpha"
      assert second.team_id == team2.id
      assert second.total_score == 150
      assert second.team_name == "Team Beta"
      assert third.team_id == team3.id
      assert third.total_score == 80
      assert third.team_name == "Team Gamma"
    end
  end

  describe "get_user_cohort_for_course/2" do
    test "returns the active cohort a user belongs to for a given course" do
      user = insert(:account)
      course = insert(:course)
      cohort = insert(:cohort, type: :team)

      insert(:cohort_membership, account_id: user.id, cohort_id: cohort.id)

      insert(:enrollment, course_id: course.id, cohort_id: cohort.id, status: :active)

      result = Athena.Learning.Enrollments.get_user_cohort_for_course(user.id, course.id)
      assert result.id == cohort.id
    end

    test "returns nil if user is not in any cohort for the course" do
      user = insert(:account)
      course = insert(:course)

      assert nil == Athena.Learning.Enrollments.get_user_cohort_for_course(user.id, course.id)
    end

    test "returns nil if the cohort enrollment is dropped" do
      user = insert(:account)
      course = insert(:course)
      cohort = insert(:cohort)

      insert(:cohort_membership, account_id: user.id, cohort_id: cohort.id)
      insert(:enrollment, course_id: course.id, cohort_id: cohort.id, status: :dropped)

      assert nil == Athena.Learning.Enrollments.get_user_cohort_for_course(user.id, course.id)
    end
  end

  describe "ACL: list_submissions/2 and get_submission!/2" do
    setup do
      role = insert(:role, permissions: ["grading.read"])
      instructor = insert(:account, role: role)
      student = insert(:account, role: insert(:role, permissions: []))

      %{instructor: instructor, student: student}
    end

    test "instructor with grading.read can list submissions", %{instructor: instructor} do
      insert_list(3, :submission)

      {:ok, {submissions, meta}} = Submissions.list_submissions(instructor, %{})
      assert length(submissions) == 3
      assert meta.total_count == 3
    end

    test "instructor with grading.read can get specific submission", %{instructor: instructor} do
      submission = insert(:submission)

      fetched = Submissions.get_submission!(instructor, submission.id)
      assert fetched.id == submission.id
    end

    test "student without grading.read cannot list submissions", %{student: student} do
      insert_list(3, :submission)

      {:ok, {submissions, _meta}} = Submissions.list_submissions(student, %{})
      assert submissions == []
    end

    test "student without grading.read cannot get specific submission", %{student: student} do
      submission = insert(:submission)

      assert_raise Ecto.NoResultsError, fn ->
        Submissions.get_submission!(student, submission.id)
      end
    end
  end

  describe "ACL: own_only policy for submissions" do
    setup do
      role =
        insert(:role,
          permissions: ["grading.read", "courses.read"],
          policies: %{
            "grading.read" => ["own_only"],
            "courses.read" => ["own_only"]
          }
        )

      instructor_account = insert(:account, role: role)
      student_account = insert(:account, role: insert(:role, permissions: []))

      %{instructor: instructor_account, student: student_account}
    end

    test "sees submissions for owned courses (via course ownership)", %{
      instructor: instructor,
      student: student
    } do
      course = insert(:course, owner_id: instructor.id)
      section = insert(:section, course: course)
      block = insert(:block, section: section)

      sub = insert(:submission, account_id: student.id, block_id: block.id)

      {:ok, {submissions, _meta}} = Submissions.list_submissions(instructor, %{})

      assert length(submissions) == 1
      assert hd(submissions).id == sub.id
    end

    test "sees submissions for assigned cohorts (even if course is owned by someone else)", %{
      instructor: instructor,
      student: student
    } do
      other_admin = insert(:account)

      course = insert(:course, owner_id: other_admin.id)
      section = insert(:section, course: course)
      block = insert(:block, section: section)

      cohort = insert(:cohort)
      instructor_profile = insert(:instructor, owner_id: instructor.id)
      insert(:cohort_instructor, instructor_id: instructor_profile.id, cohort_id: cohort.id)

      sub = insert(:submission, account_id: student.id, block_id: block.id, cohort_id: cohort.id)

      {:ok, {submissions, _meta}} = Submissions.list_submissions(instructor, %{})

      assert length(submissions) == 1
      assert hd(submissions).id == sub.id
    end

    test "does not see submissions for unassigned cohorts and courses", %{
      instructor: instructor,
      student: student
    } do
      other_admin = insert(:account)

      course = insert(:course, owner_id: other_admin.id)
      section = insert(:section, course: course)
      block = insert(:block, section: section)

      other_cohort = insert(:cohort)

      insert(:submission, account_id: student.id, block_id: block.id, cohort_id: other_cohort.id)
      insert(:submission, account_id: student.id, block_id: block.id, cohort_id: nil)

      {:ok, {submissions, _meta}} = Submissions.list_submissions(instructor, %{})

      assert submissions == []
    end
  end

  describe "delete_submission_with_rollback/2" do
    setup do
      admin_role = insert(:role, permissions: ["grading.update", "courses.read"])
      admin = insert(:account, role: admin_role)
      student = insert(:account, role: insert(:role, permissions: []))

      course = insert(:course)
      section = insert(:section, course: course)
      block = insert(:block, section: section)

      %{admin: admin, student: student, course: course, section: section, block: block}
    end

    test "deletes submission and rolls back progress if user has permission", %{
      admin: admin,
      student: student,
      section: section,
      block: block
    } do
      submission =
        insert(:submission, account_id: student.id, block_id: block.id, status: :pending)

      Athena.Learning.Progress.mark_completed(student.id, block.id)
      assert block.id in Athena.Learning.Progress.completed_block_ids(student.id, section.id)

      assert {:ok, deleted_sub} =
               Submissions.delete_submission_with_rollback(admin, submission)

      assert deleted_sub.id == submission.id

      assert_raise Ecto.NoResultsError, fn ->
        Submissions.get_submission!(admin, submission.id)
      end

      refute block.id in Athena.Learning.Progress.completed_block_ids(student.id, section.id)
    end

    test "returns unauthorized if user lacks permission", %{
      student: student,
      block: block
    } do
      submission = insert(:submission, account_id: student.id, block_id: block.id)

      assert {:error, :unauthorized} =
               Submissions.delete_submission_with_rollback(student, submission)
    end
  end

  describe "ACL: own_only policy for delete_submission_with_rollback/2" do
    setup do
      role =
        insert(:role,
          permissions: ["grading.update", "courses.read"],
          policies: %{
            "grading.update" => ["own_only"],
            "courses.read" => ["own_only"]
          }
        )

      instructor = insert(:account, role: role)
      student = insert(:account, role: insert(:role, permissions: []))

      %{instructor: instructor, student: student}
    end

    test "allows delete if instructor owns the course", %{
      instructor: instructor,
      student: student
    } do
      course = insert(:course, owner_id: instructor.id)
      section = insert(:section, course: course)
      block = insert(:block, section: section)

      submission = insert(:submission, account_id: student.id, block_id: block.id)

      assert {:ok, _deleted} =
               Submissions.delete_submission_with_rollback(instructor, submission)
    end

    test "returns unauthorized if instructor does NOT own the course", %{
      instructor: instructor,
      student: student
    } do
      other_admin = insert(:account)
      course = insert(:course, owner_id: other_admin.id)
      section = insert(:section, course: course)
      block = insert(:block, section: section)

      submission = insert(:submission, account_id: student.id, block_id: block.id)

      assert {:error, :unauthorized} =
               Submissions.delete_submission_with_rollback(instructor, submission)
    end
  end

  describe "count_attempts/3" do
    test "returns a map of attempt counts per block for individual submissions" do
      account_id = Ecto.UUID.generate()
      other_account_id = Ecto.UUID.generate()
      block_1_id = Ecto.UUID.generate()
      block_2_id = Ecto.UUID.generate()

      insert(:submission, account_id: account_id, block_id: block_1_id, cohort_id: nil)
      insert(:submission, account_id: account_id, block_id: block_1_id, cohort_id: nil)
      insert(:submission, account_id: account_id, block_id: block_1_id, cohort_id: nil)

      insert(:submission, account_id: account_id, block_id: block_2_id, cohort_id: nil)

      insert(:submission, account_id: other_account_id, block_id: block_1_id, cohort_id: nil)

      result = Submissions.count_attempts(account_id, [block_1_id, block_2_id])

      assert map_size(result) == 2
      assert result[block_1_id] == 3
      assert result[block_2_id] == 1
    end

    test "returns a map of attempt counts per block for team submissions (cohort scope)" do
      student_a = Ecto.UUID.generate()
      student_b = Ecto.UUID.generate()
      team = insert(:cohort, type: :team)
      other_team = insert(:cohort, type: :team)
      block_id = Ecto.UUID.generate()

      insert(:submission, account_id: student_a, block_id: block_id, cohort_id: team.id)
      insert(:submission, account_id: student_b, block_id: block_id, cohort_id: team.id)

      insert(:submission, account_id: student_a, block_id: block_id, cohort_id: other_team.id)

      result = Submissions.count_attempts(student_a, [block_id], team.id)

      assert map_size(result) == 1
      assert result[block_id] == 2
    end

    test "returns an empty map if no submissions exist for the specified blocks" do
      account_id = Ecto.UUID.generate()
      block_id = Ecto.UUID.generate()

      assert %{} == Submissions.count_attempts(account_id, [block_id])
    end
  end

  describe "save_draft/4" do
    test "creates a new draft submission in DB and caches it" do
      user = insert(:account)
      block = insert(:block)
      content = %{"type" => :quiz_question, "text_answer" => "My draft answer"}

      assert {:ok, draft} = Submissions.save_draft(user, block.id, content)

      assert draft.status == :draft
      assert draft.account_id == user.id
      assert draft.block_id == block.id
      assert draft.content["text_answer"] == "My draft answer"
      assert draft.cohort_id == nil
      assert DraftCache.get_draft(user.id, nil, block.id) == content
    end

    test "updates existing draft instead of creating a new one (upsert)" do
      user = insert(:account)
      block = insert(:block)

      {:ok, draft1} =
        Submissions.save_draft(user, block.id, %{
          "type" => :quiz_question,
          "text_answer" => "First version"
        })

      {:ok, draft2} =
        Submissions.save_draft(user, block.id, %{
          "type" => :quiz_question,
          "text_answer" => "Second version"
        })

      assert draft1.id == draft2.id
      assert draft2.content["text_answer"] == "Second version"

      drafts =
        Repo.all(
          from s in Submission,
            where: s.account_id == ^user.id and s.block_id == ^block.id and s.status == :draft
        )

      assert length(drafts) == 1
    end

    test "creates team draft when cohort_id is provided" do
      user = insert(:account)
      teammate = insert(:account)
      team = insert(:cohort, type: :team)
      block = insert(:block)
      content = %{"type" => :quiz_question, "text_answer" => "Team answer"}

      assert {:ok, draft} = Submissions.save_draft(user, block.id, content, team.id)

      assert draft.cohort_id == team.id
      assert draft.account_id == user.id
      assert draft.content["text_answer"] == "Team answer"

      assert DraftCache.get_draft(user.id, team.id, block.id) == content
      assert DraftCache.get_draft(teammate.id, team.id, block.id) == content
    end

    test "broadcasts draft update via PubSub for team submissions" do
      user = insert(:account)
      team = insert(:cohort, type: :team)
      block = insert(:block)
      content = %{"type" => :quiz_question, "text_answer" => "Live collab"}

      DraftCache.subscribe_to_draft_updates(team.id, block.id)

      {:ok, _draft} = Submissions.save_draft(user, block.id, content, team.id)

      assert_receive {:draft_updated,
                      %{block_id: block_id, content: received_content, updater_id: updater_id}}

      assert block_id == block.id
      assert received_content == content
      assert updater_id == user.id
    end

    test "does NOT broadcast for individual submissions" do
      user = insert(:account)
      block = insert(:block)
      content = %{"type" => :quiz_question, "text_answer" => "Solo work"}

      {:ok, _draft} = Submissions.save_draft(user, block.id, content)

      refute_receive {:draft_updated, _}
    end
  end

  describe "get_draft/3" do
    test "returns draft content from cache if present" do
      user = insert(:account)
      block = insert(:block)
      content = %{"type" => "quiz_question", "text_answer" => "Cached answer"}

      DraftCache.save_draft(user.id, nil, block.id, content)

      assert Submissions.get_draft(user.id, block.id) == content
    end

    test "falls back to DB and restores to cache if cache is empty" do
      user = insert(:account)
      block = insert(:block)
      content = %{"type" => "quiz_question", "text_answer" => "DB answer"}

      {:ok, _draft} = Submissions.save_draft(user, block.id, content)

      DraftCache.clear_draft(user.id, nil, block.id)

      result = Submissions.get_draft(user.id, block.id)
      assert result == content
      assert DraftCache.get_draft(user.id, nil, block.id) == content
    end

    test "returns nil if draft does not exist in cache or DB" do
      user = insert(:account)
      block = insert(:block)

      assert Submissions.get_draft(user.id, block.id) == nil
    end

    test "returns team draft when cohort_id is provided" do
      user = insert(:account)
      teammate = insert(:account)
      team = insert(:cohort, type: :team)
      block = insert(:block)
      content = %{"type" => :quiz_question, "text_answer" => "Shared team draft"}

      {:ok, _draft} = Submissions.save_draft(teammate, block.id, content, team.id)

      assert Submissions.get_draft(user.id, block.id, team.id) == content
    end

    test "does not leak individual drafts to team context" do
      user = insert(:account)
      team = insert(:cohort, type: :team)
      block = insert(:block)
      individual_content = %{"type" => :quiz_question, "text_answer" => "My private work"}
      team_content = %{"type" => :quiz_question, "text_answer" => "Team work"}

      {:ok, _} = Submissions.save_draft(user, block.id, individual_content)

      {:ok, _} = Submissions.save_draft(user, block.id, team_content, team.id)

      assert Submissions.get_draft(user.id, block.id, team.id) == team_content
      assert Submissions.get_draft(user.id, block.id) == individual_content
    end
  end

  describe "clear_draft/3" do
    test "removes draft from cache but keeps it in DB" do
      user = insert(:account)
      block = insert(:block)
      content = %{"type" => "quiz_question", "text_answer" => "To be cleared"}

      {:ok, _draft} = Submissions.save_draft(user, block.id, content)

      assert DraftCache.get_draft(user.id, nil, block.id) == content
      Submissions.clear_draft(user.id, block.id)

      assert DraftCache.get_draft(user.id, nil, block.id) == nil
      assert Submissions.get_draft(user.id, block.id) == content
    end
  end

  describe "create_submission/2 with draft upsert" do
    test "updates existing draft instead of creating new submission" do
      user = insert(:account)
      block = insert(:block)

      {:ok, draft} =
        Submissions.save_draft(user, block.id, %{
          "type" => :quiz_question,
          "text_answer" => "Draft version"
        })

      attrs = %{
        "block_id" => block.id,
        "status" => :pending,
        "content" => %{"type" => :quiz_question, "text_answer" => "Final answer"}
      }

      assert {:ok, submission} = Submissions.create_submission(user, attrs)
      assert submission.id == draft.id
      assert submission.status == :pending
      assert submission.content["text_answer"] == "Final answer"

      submissions =
        Repo.all(
          from s in Submission, where: s.account_id == ^user.id and s.block_id == ^block.id
        )

      assert length(submissions) == 1
      assert DraftCache.get_draft(user.id, nil, block.id) == nil
    end

    test "creates new submission when no draft exists" do
      user = insert(:account)
      block = insert(:block)

      attrs = %{
        "block_id" => block.id,
        "status" => :pending,
        "content" => %{"type" => :quiz_question, "text_answer" => "Fresh submission"}
      }

      assert {:ok, submission} = Submissions.create_submission(user, attrs)

      assert submission.status == :pending
      assert submission.account_id == user.id
      assert submission.block_id == block.id
    end

    test "upserts team draft correctly" do
      user = insert(:account)
      team = insert(:cohort, type: :team)
      block = insert(:block)

      {:ok, draft} =
        Submissions.save_draft(
          user,
          block.id,
          %{"type" => :quiz_question, "text_answer" => "Team draft"},
          team.id
        )

      attrs = %{
        "block_id" => block.id,
        "cohort_id" => team.id,
        "status" => :pending,
        "content" => %{"type" => :quiz_question, "text_answer" => "Final team answer"}
      }

      assert {:ok, submission} = Submissions.create_submission(user, attrs)

      assert submission.id == draft.id
      assert submission.cohort_id == team.id
      assert submission.content["text_answer"] == "Final team answer"
      assert DraftCache.get_draft(user.id, team.id, block.id) == nil
    end
  end

  describe "draft filtering in queries" do
    test "list_submissions excludes drafts from results" do
      admin_role = insert(:role, permissions: ["grading.read"])
      admin = insert(:account, role: admin_role)
      student = insert(:account)
      block = insert(:block)

      insert(:submission, account_id: student.id, block_id: block.id, status: :pending)

      Submissions.save_draft(student, block.id, %{
        "type" => :quiz_question,
        "text_answer" => "Hidden draft"
      })

      {:ok, {submissions, meta}} = Submissions.list_submissions(admin, %{})

      assert length(submissions) == 1
      assert hd(submissions).status == :pending
      assert meta.total_count == 1
    end

    test "get_submission/3 excludes drafts" do
      account_id = Ecto.UUID.generate()
      block_id = Ecto.UUID.generate()

      insert(:submission, account_id: account_id, block_id: block_id, status: :draft)

      regular_sub =
        insert(:submission, account_id: account_id, block_id: block_id, status: :pending)

      fetched = Submissions.get_submission(account_id, block_id)
      assert fetched.id == regular_sub.id
      assert fetched.status == :pending
    end

    test "get_latest_submissions/3 excludes drafts" do
      account_id = Ecto.UUID.generate()
      block_1_id = Ecto.UUID.generate()
      block_2_id = Ecto.UUID.generate()

      insert(:submission,
        account_id: account_id,
        block_id: block_1_id,
        status: :draft,
        score: 100
      )

      regular_sub =
        insert(:submission,
          account_id: account_id,
          block_id: block_2_id,
          status: :graded,
          score: 80
        )

      result = Submissions.get_latest_submissions(account_id, [block_1_id, block_2_id])

      assert map_size(result) == 1
      assert result[block_2_id].id == regular_sub.id
      refute Map.has_key?(result, block_1_id)
    end

    test "count_attempts/3 does not count drafts" do
      account_id = Ecto.UUID.generate()
      block_id = Ecto.UUID.generate()

      insert(:submission, account_id: account_id, block_id: block_id, status: :pending)
      insert(:submission, account_id: account_id, block_id: block_id, status: :graded)
      insert(:submission, account_id: account_id, block_id: block_id, status: :draft)
      insert(:submission, account_id: account_id, block_id: block_id, status: :draft)
      insert(:submission, account_id: account_id, block_id: block_id, status: :draft)

      result = Submissions.count_attempts(account_id, [block_id])

      assert result[block_id] == 2
    end

    test "get_team_leaderboard/1 ignores draft submissions" do
      course = insert(:course)
      section = insert(:section, course: course)
      block = insert(:block, section: section)
      team = insert(:cohort, name: "Drafters", type: :team)

      insert(:enrollment, course_id: course.id, cohort_id: team.id)

      insert(:submission,
        block_id: block.id,
        cohort_id: team.id,
        score: 100,
        status: :draft
      )

      insert(:submission,
        block_id: block.id,
        cohort_id: team.id,
        score: 50,
        status: :graded
      )

      leaderboard = Submissions.get_team_leaderboard(course.id)

      assert length(leaderboard) == 1
      [team_stats] = leaderboard
      assert team_stats.total_score == 50
    end
  end
end
