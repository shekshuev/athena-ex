defmodule Athena.Learning.EnrollmentsTest do
  use Athena.DataCase, async: true

  alias Athena.Learning.Enrollments
  alias Athena.Learning.Enrollment
  import Athena.Factory

  setup do
    admin_role = insert(:role, permissions: ["admin", "enrollments.read", "courses.read"])
    admin = insert(:account, role: admin_role)

    inst_role =
      insert(:role,
        permissions: ["enrollments.read", "courses.read"],
        policies: %{
          "enrollments.read" => ["own_only"],
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

  describe "enroll_cohort/3" do
    test "creates an active enrollment by default" do
      cohort = insert(:cohort)
      course = insert(:course)

      assert {:ok, %Enrollment{} = enrollment} = Enrollments.enroll_cohort(cohort.id, course.id)

      assert enrollment.cohort_id == cohort.id
      assert enrollment.course_id == course.id
      assert enrollment.status == :active
    end

    test "allows specifying a different status" do
      cohort = insert(:cohort)
      course = insert(:course)

      assert {:ok, %Enrollment{} = enrollment} =
               Enrollments.enroll_cohort(cohort.id, course.id, :completed)

      assert enrollment.status == :completed
    end

    test "enforces unique constraint per cohort and course" do
      cohort = insert(:cohort)
      course = insert(:course)

      assert {:ok, _} = Enrollments.enroll_cohort(cohort.id, course.id)
      assert {:error, changeset} = Enrollments.enroll_cohort(cohort.id, course.id)
      assert "has already been taken" in errors_on(changeset).course_id
    end
  end

  describe "list_cohort_enrollments/3 (With ACL)" do
    test "admin sees all enrollments", %{admin: admin} do
      cohort = insert(:cohort)
      course1 = insert(:course)
      course2 = insert(:course)

      Enrollments.enroll_cohort(cohort.id, course1.id)
      Enrollments.enroll_cohort(cohort.id, course2.id)

      other_cohort = insert(:cohort)
      other_course = insert(:course)
      Enrollments.enroll_cohort(other_cohort.id, other_course.id)

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
      inst_profile: inst_profile
    } do
      course = insert(:course)
      cohort = insert(:cohort)

      Athena.Learning.Cohorts.update_cohort(cohort, %{"instructor_ids" => [inst_profile.id]})
      Enrollments.enroll_cohort(cohort.id, course.id)

      {:ok, {enrollments, _meta}} =
        Enrollments.list_cohort_enrollments(instructor, cohort.id, %{})

      assert length(enrollments) == 1
    end

    test "instructor sees enrollment if they own the course (even if cohort is not theirs)", %{
      instructor: instructor
    } do
      course = insert(:course, owner_id: instructor.id)
      cohort = insert(:cohort)
      Enrollments.enroll_cohort(cohort.id, course.id)

      {:ok, {enrollments, _meta}} =
        Enrollments.list_cohort_enrollments(instructor, cohort.id, %{})

      assert length(enrollments) == 1
    end

    test "instructor does NOT see enrollment if they own neither the course nor the cohort", %{
      instructor: instructor,
      other_instructor: other_instructor,
      other_inst_profile: other_inst_profile
    } do
      course = insert(:course, owner_id: other_instructor.id)
      cohort = insert(:cohort)

      Athena.Learning.Cohorts.update_cohort(cohort, %{"instructor_ids" => [other_inst_profile.id]})

      Enrollments.enroll_cohort(cohort.id, course.id)

      {:ok, {enrollments, _meta}} =
        Enrollments.list_cohort_enrollments(instructor, cohort.id, %{})

      assert enrollments == []
    end

    test "enriches enrollments with course data from Content context", %{admin: admin} do
      cohort = insert(:cohort)
      course = insert(:course, title: "Elixir Magic")

      Enrollments.enroll_cohort(cohort.id, course.id)

      {:ok, {enrollments, _meta}} = Enrollments.list_cohort_enrollments(admin, cohort.id, %{})

      enrollment = hd(enrollments)
      assert enrollment.course.id == course.id
      assert enrollment.course.title == "Elixir Magic"
    end
  end

  describe "get_enrollment!/1" do
    test "returns an enriched enrollment if it exists" do
      cohort = insert(:cohort)
      course = insert(:course, title: "Advanced OTP")
      {:ok, enrollment} = Enrollments.enroll_cohort(cohort.id, course.id)

      fetched = Enrollments.get_enrollment!(enrollment.id)

      assert fetched.id == enrollment.id
      assert fetched.cohort.id == cohort.id
      assert fetched.course.title == "Advanced OTP"
    end

    test "raises error if enrollment does not exist" do
      assert_raise Ecto.NoResultsError, fn ->
        Enrollments.get_enrollment!(Ecto.UUID.generate())
      end
    end
  end

  describe "update_enrollment/2" do
    test "updates the enrollment status" do
      cohort = insert(:cohort)
      course = insert(:course)
      {:ok, enrollment} = Enrollments.enroll_cohort(cohort.id, course.id)

      assert {:ok, updated} = Enrollments.update_enrollment(enrollment, %{status: :dropped})
      assert updated.status == :dropped
    end
  end

  describe "delete_enrollment/1" do
    test "deletes the enrollment record" do
      cohort = insert(:cohort)
      course = insert(:course)
      {:ok, enrollment} = Enrollments.enroll_cohort(cohort.id, course.id)

      assert {:ok, _deleted} = Enrollments.delete_enrollment(enrollment)

      assert_raise Ecto.NoResultsError, fn ->
        Enrollments.get_enrollment!(enrollment.id)
      end
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
      Enrollments.enroll_cohort(cohort.id, course.id)

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

    test "filters out duplicates if enrolled both directly and via cohort" do
      student = insert(:account)
      cohort = insert(:cohort)
      course = insert(:course, status: :published)

      Athena.Learning.Cohorts.add_student_to_cohort(cohort.id, student.id)
      Enrollments.enroll_cohort(cohort.id, course.id)

      %Enrollment{}
      |> Enrollment.changeset(%{account_id: student.id, course_id: course.id, status: :active})
      |> Athena.Repo.insert!()

      enrollments = Enrollments.list_student_enrollments(student.id)

      assert length(enrollments) == 1
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
      Enrollments.enroll_cohort(cohort.id, course.id)

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
