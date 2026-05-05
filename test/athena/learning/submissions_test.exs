defmodule Athena.Learning.SubmissionsTest do
  use Athena.DataCase, async: true

  alias Athena.Learning.Submissions
  alias Athena.Learning.Submission
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
end
