defmodule Athena.Learning.EnrollmentsTest do
  use Athena.DataCase, async: true

  alias Athena.Learning.Enrollments
  alias Athena.Learning.Enrollment
  import Athena.Factory

  setup do
    admin_role =
      insert(:role,
        permissions: [
          "admin"
        ]
      )

    admin = insert(:account, role: admin_role)

    inst_role =
      insert(:role,
        permissions: [
          "cohorts.read",
          "cohorts.update",
          "courses.read"
        ],
        policies: %{
          "cohorts.read" => ["own_only"],
          "cohorts.update" => ["own_only"],
          "courses.read" => ["own_only"]
        }
      )

    instructor = insert(:account, role: inst_role)
    inst_profile = insert(:instructor, owner_id: instructor.id)

    other_instructor = insert(:account, role: inst_role)
    other_inst_profile = insert(:instructor, owner_id: other_instructor.id)

    %{
      admin: admin,
      instructor: instructor,
      inst_profile: inst_profile,
      other_instructor: other_instructor,
      other_inst_profile: other_inst_profile
    }
  end

  describe "enroll_cohort/4" do
    test "creates an active enrollment by default", %{admin: admin} do
      cohort = insert(:cohort, owner_id: admin.id)
      course = insert(:course, owner_id: admin.id)

      assert {:ok, %Enrollment{} = enrollment} =
               Enrollments.enroll_cohort(admin, cohort.id, course.id)

      assert enrollment.cohort_id == cohort.id
      assert enrollment.course_id == course.id
      assert enrollment.status == :active
    end

    test "allows specifying a different status", %{admin: admin} do
      cohort = insert(:cohort, owner_id: admin.id)
      course = insert(:course, owner_id: admin.id)

      assert {:ok, %Enrollment{} = enrollment} =
               Enrollments.enroll_cohort(admin, cohort.id, course.id, :completed)

      assert enrollment.status == :completed
    end

    test "enforces unique constraint per cohort and course", %{admin: admin} do
      cohort = insert(:cohort, owner_id: admin.id)
      course = insert(:course, owner_id: admin.id)

      assert {:ok, _} = Enrollments.enroll_cohort(admin, cohort.id, course.id)
      assert {:error, changeset} = Enrollments.enroll_cohort(admin, cohort.id, course.id)
      assert "has already been taken" in errors_on(changeset).course_id
    end

    test "enforces type matching between cohorts and courses", %{admin: admin} do
      team_cohort = insert(:cohort, type: :team, owner_id: admin.id)
      academic_cohort = insert(:cohort, type: :academic, owner_id: admin.id)

      standard_course = insert(:course, type: :standard, owner_id: admin.id)
      competition_course = insert(:course, type: :competition, owner_id: admin.id)

      assert {:ok, _} = Enrollments.enroll_cohort(admin, team_cohort.id, competition_course.id)
      assert {:ok, _} = Enrollments.enroll_cohort(admin, academic_cohort.id, standard_course.id)

      assert {:error, error_msg} =
               Enrollments.enroll_cohort(admin, team_cohort.id, standard_course.id)

      assert error_msg == "Cannot assign a Competition Team to a Standard Course."

      assert {:error, error_msg} =
               Enrollments.enroll_cohort(admin, academic_cohort.id, competition_course.id)

      assert error_msg == "Cannot assign an Academic Group to a Competition."
    end

    test "returns error if user has no access to the cohort", %{admin: admin} do
      user_no_access = insert(:account, role: insert(:role, permissions: []))

      cohort = insert(:cohort, owner_id: admin.id)
      course = insert(:course, owner_id: admin.id)

      assert {:error, "Cohort or Course not found or access denied."} =
               Enrollments.enroll_cohort(user_no_access, cohort.id, course.id)
    end

    test "returns unauthorized if instructor can teach in cohort but cannot read the course", %{
      instructor: inst,
      admin: admin
    } do
      cohort = insert(:cohort, owner_id: inst.id)
      course = insert(:course, owner_id: admin.id)

      assert {:error, :unauthorized} = Enrollments.enroll_cohort(inst, cohort.id, course.id)
    end
  end

  describe "list_cohort_enrollments/3 (With ACL)" do
    test "admin sees all enrollments", %{admin: admin} do
      cohort = insert(:cohort, owner_id: admin.id)
      course1 = insert(:course, owner_id: admin.id)
      course2 = insert(:course, owner_id: admin.id)

      Enrollments.enroll_cohort(admin, cohort.id, course1.id)
      Enrollments.enroll_cohort(admin, cohort.id, course2.id)

      other_cohort = insert(:cohort, owner_id: admin.id)
      other_course = insert(:course, owner_id: admin.id)
      Enrollments.enroll_cohort(admin, other_cohort.id, other_course.id)

      {:ok, {enrollments, meta}} = Enrollments.list_cohort_enrollments(admin, cohort.id, %{})

      assert meta.total_count == 2
      assert length(enrollments) == 2

      fetched_course_ids = Enum.map(enrollments, & &1.course_id)
      assert course1.id in fetched_course_ids
      assert course2.id in fetched_course_ids
      refute other_course.id in fetched_course_ids
    end

    test "instructor sees enrollment if they are assigned to the cohort", %{
      instructor: instructor,
      inst_profile: inst_profile,
      admin: admin
    } do
      course = insert(:course, owner_id: admin.id)
      cohort = insert(:cohort, owner_id: admin.id)

      Athena.Learning.Cohorts.update_cohort(admin, cohort, %{
        "instructor_ids" => [inst_profile.id]
      })

      Enrollments.enroll_cohort(admin, cohort.id, course.id)

      {:ok, {enrollments, _meta}} =
        Enrollments.list_cohort_enrollments(instructor, cohort.id, %{})

      assert length(enrollments) == 1
    end

    test "instructor sees enrollment if they own the course (even if cohort is not theirs)", %{
      instructor: instructor,
      admin: admin
    } do
      course = insert(:course, owner_id: instructor.id)
      cohort = insert(:cohort, owner_id: admin.id)
      Enrollments.enroll_cohort(admin, cohort.id, course.id)

      {:ok, {enrollments, _meta}} =
        Enrollments.list_cohort_enrollments(instructor, cohort.id, %{})

      assert length(enrollments) == 1
    end

    test "instructor does NOT see enrollment if they own neither the course nor the cohort", %{
      instructor: instructor,
      other_instructor: other_instructor,
      other_inst_profile: other_inst_profile,
      admin: admin
    } do
      course = insert(:course, owner_id: other_instructor.id)
      cohort = insert(:cohort, owner_id: admin.id)

      Athena.Learning.Cohorts.update_cohort(admin, cohort, %{
        "instructor_ids" => [other_inst_profile.id]
      })

      Enrollments.enroll_cohort(admin, cohort.id, course.id)

      {:ok, {enrollments, _meta}} =
        Enrollments.list_cohort_enrollments(instructor, cohort.id, %{})

      assert enrollments == []
    end

    test "enriches enrollments with course data from Content context", %{admin: admin} do
      cohort = insert(:cohort, owner_id: admin.id)
      course = insert(:course, title: "Elixir Magic", owner_id: admin.id)

      Enrollments.enroll_cohort(admin, cohort.id, course.id)

      {:ok, {enrollments, _meta}} = Enrollments.list_cohort_enrollments(admin, cohort.id, %{})

      enrollment = hd(enrollments)
      assert enrollment.course.id == course.id
      assert enrollment.course.title == "Elixir Magic"
    end
  end

  describe "get_enrollment!/2" do
    test "returns an enriched enrollment if it exists", %{admin: admin} do
      cohort = insert(:cohort, owner_id: admin.id)
      course = insert(:course, title: "Advanced OTP", owner_id: admin.id)
      {:ok, enrollment} = Enrollments.enroll_cohort(admin, cohort.id, course.id)

      fetched = Enrollments.get_enrollment!(admin, enrollment.id)

      assert fetched.id == enrollment.id
      assert fetched.cohort.id == cohort.id
      assert fetched.course.title == "Advanced OTP"
    end

    test "raises error if enrollment does not exist", %{admin: admin} do
      assert_raise Ecto.NoResultsError, fn ->
        Enrollments.get_enrollment!(admin, Ecto.UUID.generate())
      end
    end

    test "raises error if instructor does not own the related entities", %{
      admin: admin,
      instructor: inst
    } do
      cohort = insert(:cohort, owner_id: admin.id)
      course = insert(:course, owner_id: admin.id)
      {:ok, enrollment} = Enrollments.enroll_cohort(admin, cohort.id, course.id)

      assert_raise Ecto.NoResultsError, fn ->
        Enrollments.get_enrollment!(inst, enrollment.id)
      end
    end
  end

  describe "update_enrollment/3" do
    test "updates the enrollment status", %{admin: admin} do
      cohort = insert(:cohort, owner_id: admin.id)
      course = insert(:course, owner_id: admin.id)
      {:ok, enrollment} = Enrollments.enroll_cohort(admin, cohort.id, course.id)

      assert {:ok, updated} =
               Enrollments.update_enrollment(admin, enrollment, %{status: :dropped})

      assert updated.status == :dropped
    end

    test "returns unauthorized if user cannot teach in cohort", %{admin: admin, instructor: inst} do
      cohort = insert(:cohort, owner_id: admin.id)
      course = insert(:course, owner_id: admin.id)
      {:ok, enrollment} = Enrollments.enroll_cohort(admin, cohort.id, course.id)

      assert {:error, :unauthorized} =
               Enrollments.update_enrollment(inst, enrollment, %{status: :dropped})
    end
  end

  describe "delete_enrollment/2" do
    test "deletes the enrollment record", %{admin: admin} do
      cohort = insert(:cohort, owner_id: admin.id)
      course = insert(:course, owner_id: admin.id)
      {:ok, enrollment} = Enrollments.enroll_cohort(admin, cohort.id, course.id)

      assert {:ok, _deleted} = Enrollments.delete_enrollment(admin, enrollment)

      assert_raise Ecto.NoResultsError, fn ->
        Enrollments.get_enrollment!(admin, enrollment.id)
      end
    end

    test "returns unauthorized if user cannot teach in cohort", %{admin: admin, instructor: inst} do
      cohort = insert(:cohort, owner_id: admin.id)
      course = insert(:course, owner_id: admin.id)
      {:ok, enrollment} = Enrollments.enroll_cohort(admin, cohort.id, course.id)

      assert {:error, :unauthorized} = Enrollments.delete_enrollment(inst, enrollment)
    end
  end

  describe "list_student_enrollments/1" do
    test "returns direct enrollments for the student (published only)" do
      student = insert(:account)
      course = insert(:course, status: :published)

      %Enrollment{}
      |> Enrollment.changeset(%{account_id: student.id, course_id: course.id, status: :active})
      |> Athena.Repo.insert!()

      enrollments = Enrollments.list_student_enrollments(student.id)

      assert length(enrollments) == 1
      assert hd(enrollments).course.id == course.id
    end

    test "returns cohort-based enrollments for the student (published only)" do
      student = insert(:account)
      cohort = insert(:cohort)
      course = insert(:course, status: :published)

      Athena.Learning.Cohorts.add_student_to_cohort(cohort.id, student.id)

      %Enrollment{}
      |> Enrollment.changeset(%{cohort_id: cohort.id, course_id: course.id, status: :active})
      |> Athena.Repo.insert!()

      enrollments = Enrollments.list_student_enrollments(student.id)

      assert length(enrollments) == 1
      assert hd(enrollments).course.id == course.id
    end

    test "excludes enrollments for draft and archived courses" do
      student = insert(:account)
      draft_course = insert(:course, status: :draft)
      archived_course = insert(:course, status: :archived)
      published_course = insert(:course, status: :published)

      %Enrollment{}
      |> Enrollment.changeset(%{
        account_id: student.id,
        course_id: draft_course.id,
        status: :active
      })
      |> Athena.Repo.insert!()

      %Enrollment{}
      |> Enrollment.changeset(%{
        account_id: student.id,
        course_id: archived_course.id,
        status: :active
      })
      |> Athena.Repo.insert!()

      %Enrollment{}
      |> Enrollment.changeset(%{
        account_id: student.id,
        course_id: published_course.id,
        status: :active
      })
      |> Athena.Repo.insert!()

      enrollments = Enrollments.list_student_enrollments(student.id)

      assert length(enrollments) == 1
      assert hd(enrollments).course.id == published_course.id
    end

    test "excludes dropped enrollments and soft-deleted courses" do
      student = insert(:account)
      active_course = insert(:course, status: :published)
      deleted_course = insert(:course, status: :published, deleted_at: DateTime.utc_now())

      %Enrollment{}
      |> Enrollment.changeset(%{
        account_id: student.id,
        course_id: active_course.id,
        status: :dropped
      })
      |> Athena.Repo.insert!()

      %Enrollment{}
      |> Enrollment.changeset(%{
        account_id: student.id,
        course_id: deleted_course.id,
        status: :active
      })
      |> Athena.Repo.insert!()

      enrollments = Enrollments.list_student_enrollments(student.id)

      assert enrollments == []
    end
  end

  describe "has_access?/2" do
    test "returns true if student is enrolled directly and course is published" do
      student = insert(:account)
      course = insert(:course, status: :published)

      %Enrollment{}
      |> Enrollment.changeset(%{account_id: student.id, course_id: course.id, status: :active})
      |> Athena.Repo.insert!()

      assert Enrollments.has_access?(student.id, course.id)
    end

    test "returns true if student is enrolled via cohort and course is published" do
      student = insert(:account)
      cohort = insert(:cohort)
      course = insert(:course, status: :published)

      Athena.Learning.Cohorts.add_student_to_cohort(cohort.id, student.id)

      %Enrollment{}
      |> Enrollment.changeset(%{cohort_id: cohort.id, course_id: course.id, status: :active})
      |> Athena.Repo.insert!()

      assert Enrollments.has_access?(student.id, course.id)
    end

    test "returns false if student is enrolled but course is NOT published" do
      student = insert(:account)
      draft_course = insert(:course, status: :draft)
      archived_course = insert(:course, status: :archived)

      %Enrollment{}
      |> Enrollment.changeset(%{
        account_id: student.id,
        course_id: draft_course.id,
        status: :active
      })
      |> Athena.Repo.insert!()

      %Enrollment{}
      |> Enrollment.changeset(%{
        account_id: student.id,
        course_id: archived_course.id,
        status: :active
      })
      |> Athena.Repo.insert!()

      refute Enrollments.has_access?(student.id, draft_course.id)
      refute Enrollments.has_access?(student.id, archived_course.id)
    end

    test "returns false if student is not enrolled at all" do
      student = insert(:account)
      course = insert(:course, status: :published)

      refute Enrollments.has_access?(student.id, course.id)
    end

    test "returns false if enrollment status is dropped" do
      student = insert(:account)
      course = insert(:course, status: :published)

      %Enrollment{}
      |> Enrollment.changeset(%{account_id: student.id, course_id: course.id, status: :dropped})
      |> Athena.Repo.insert!()

      refute Enrollments.has_access?(student.id, course.id)
    end
  end
end
