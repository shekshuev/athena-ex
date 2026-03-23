defmodule Athena.Learning.EnrollmentsTest do
  use Athena.DataCase, async: true

  alias Athena.Learning.Enrollments
  alias Athena.Learning.Enrollment
  import Athena.Factory

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

  describe "list_cohort_enrollments/2" do
    test "returns paginated list of enrollments for a cohort" do
      cohort = insert(:cohort)
      course1 = insert(:course)
      course2 = insert(:course)

      Enrollments.enroll_cohort(cohort.id, course1.id)
      Enrollments.enroll_cohort(cohort.id, course2.id)

      other_cohort = insert(:cohort)
      other_course = insert(:course)
      Enrollments.enroll_cohort(other_cohort.id, other_course.id)

      {:ok, {enrollments, meta}} = Enrollments.list_cohort_enrollments(cohort.id, %{})

      assert meta.total_count == 2
      assert length(enrollments) == 2

      fetched_course_ids = Enum.map(enrollments, & &1.course_id)
      assert course1.id in fetched_course_ids
      assert course2.id in fetched_course_ids
      refute other_course.id in fetched_course_ids
    end

    test "enriches enrollments with course data from Content context" do
      cohort = insert(:cohort)
      course = insert(:course, title: "Elixir Magic")

      Enrollments.enroll_cohort(cohort.id, course.id)

      {:ok, {enrollments, _meta}} = Enrollments.list_cohort_enrollments(cohort.id, %{})

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
end
