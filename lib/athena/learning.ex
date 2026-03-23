defmodule Athena.Learning do
  @moduledoc """
  Public API for the Learning context.

  Delegates operations to specialized internal modules:
  - `Instructors`: Instructor profile management and search.
  - `Cohorts`: Cohort (group) CRUD and student memberships.
  - `Enrollments`: Assigning cohorts or students to courses.
  """

  alias Athena.Learning.{Instructors, Cohorts, Enrollments}

  defdelegate list_instructors(params \\ %{}), to: Instructors
  defdelegate search_instructors(search_query, limit \\ 10), to: Instructors
  defdelegate get_instructor!(id), to: Instructors
  defdelegate create_instructor(attrs), to: Instructors
  defdelegate update_instructor(instructor, attrs), to: Instructors
  defdelegate delete_instructor(instructor), to: Instructors

  defdelegate list_cohorts(params \\ %{}), to: Cohorts
  defdelegate get_cohort!(id), to: Cohorts
  defdelegate create_cohort(attrs), to: Cohorts
  defdelegate update_cohort(cohort, attrs), to: Cohorts
  defdelegate delete_cohort(cohort), to: Cohorts

  defdelegate list_cohort_memberships(cohort_id, params \\ %{}), to: Cohorts
  defdelegate get_cohort_membership!(id), to: Cohorts
  defdelegate add_student_to_cohort(cohort_id, account_id), to: Cohorts
  defdelegate remove_student_from_cohort(membership), to: Cohorts

  defdelegate list_cohort_enrollments(cohort_id, params \\ %{}), to: Enrollments
  defdelegate get_enrollment!(id), to: Enrollments
  defdelegate enroll_cohort(cohort_id, course_id, status \\ :active), to: Enrollments
  defdelegate update_enrollment(enrollment, attrs), to: Enrollments
  defdelegate delete_enrollment(enrollment), to: Enrollments
end
