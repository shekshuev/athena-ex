defmodule Athena.Learning do
  @moduledoc """
  Public API for the Learning context.

  Delegates operations to specialized internal modules:
  - `Instructors`: Instructor profile management and search.
  - `Cohorts`: Cohort (group) CRUD and student memberships.
  - `Enrollments`: Assigning cohorts or students to courses.
  - `Submissions`: Managing, creating, and retrieving student answers and task submissions.
  - `Progress`: Tracking completed blocks and enforcing access rules (high watermark / retrograde locks).
  - `Evaluator`: Auto-grading and synchronous evaluation of student submissions.
  """

  alias Athena.Learning.{
    Instructors,
    Cohorts,
    Enrollments,
    Submissions,
    Progress,
    Evaluator,
    Schedules
  }

  defdelegate list_instructors(user, params \\ %{}), to: Instructors
  defdelegate search_instructors(user, search_query, limit \\ 10), to: Instructors
  defdelegate get_instructor(user, id), to: Instructors
  defdelegate create_instructor(user, attrs), to: Instructors
  defdelegate update_instructor(user, instructor, attrs), to: Instructors
  defdelegate delete_instructor(user, instructor), to: Instructors

  defdelegate list_cohorts(user, params \\ %{}), to: Cohorts
  defdelegate get_cohort(user, id), to: Cohorts
  defdelegate create_cohort(user, attrs), to: Cohorts
  defdelegate update_cohort(user, cohort, attrs), to: Cohorts
  defdelegate delete_cohort(user, cohort), to: Cohorts
  defdelegate get_cohort_options(user), to: Cohorts

  defdelegate list_cohort_memberships(cohort_id, params \\ %{}), to: Cohorts
  defdelegate get_cohort_membership!(id), to: Cohorts
  defdelegate add_student_to_cohort(cohort_id, account_id), to: Cohorts
  defdelegate remove_student_from_cohort(membership), to: Cohorts

  defdelegate list_cohort_enrollments(user, cohort_id, params \\ %{}), to: Enrollments
  defdelegate get_enrollment!(user, id), to: Enrollments
  defdelegate enroll_cohort(cohort_id, course_id, status \\ :active), to: Enrollments
  defdelegate update_enrollment(user, enrollment, attrs), to: Enrollments
  defdelegate delete_enrollment(user, enrollment), to: Enrollments
  defdelegate list_student_enrollments(account_id), to: Enrollments
  defdelegate has_access?(account_id, course_id), to: Enrollments
  defdelegate get_user_cohort_for_course(account_id, course_id), to: Enrollments
  defdelegate can_manage_enrollment?(user, action, enrollment, preloaded_cohort), to: Enrollments

  defdelegate list_submissions(user, params \\ %{}), to: Submissions
  defdelegate get_submission(account_id, block_id, cohort_id \\ nil), to: Submissions
  defdelegate create_submission(user, attrs), to: Submissions
  defdelegate update_submission(user, submission, attrs), to: Submissions
  defdelegate system_update_submission(submission, attrs), to: Submissions
  defdelegate get_latest_submissions(account_id, block_ids, cohort_id \\ nil), to: Submissions
  defdelegate get_submission!(user, id), to: Submissions
  defdelegate get_team_leaderboard(course_id), to: Submissions

  defdelegate mark_completed(account_id, block_id, cohort_id \\ nil), to: Progress
  defdelegate completed_block_ids(account_id, section_id, cohort_id \\ nil), to: Progress

  defdelegate accessible_section_ids(
                user,
                course_id,
                linear_sections,
                overrides,
                cohort_id \\ nil
              ),
              to: Progress

  defdelegate evaluate_sync(submission), to: Evaluator

  defdelegate get_student_overrides(account_id, course_id, cohort_id), to: Schedules
  defdelegate list_cohort_course_overrides(cohort_id, course_id), to: Schedules
  defdelegate set_override(user, cohort, course, attrs), to: Schedules
  defdelegate clear_override(user, cohort, course, resource_type, resource_id), to: Schedules
end
