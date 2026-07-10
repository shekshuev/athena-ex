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
    Schedules,
    DraftCache
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
  defdelegate add_student_to_cohort(user, cohort_id, account_id), to: Cohorts
  defdelegate remove_student_from_cohort(user, membership), to: Cohorts
  defdelegate can_manage_cohort_processes?(user, cohort), to: Cohorts
  defdelegate can_view_cohort_processes?(user, cohort), to: Cohorts

  defdelegate list_cohort_enrollments(user, cohort_id, params \\ %{}), to: Enrollments
  defdelegate get_enrollment!(user, id), to: Enrollments
  defdelegate enroll_cohort(user, cohort_id, course_id, status \\ :active), to: Enrollments
  defdelegate update_enrollment(user, enrollment, attrs), to: Enrollments
  defdelegate delete_enrollment(user, enrollment), to: Enrollments
  defdelegate list_student_enrollments(account_id), to: Enrollments
  defdelegate has_access?(account_id, course_id), to: Enrollments
  defdelegate get_user_cohort_for_course(account_id, course_id), to: Enrollments

  defdelegate list_submissions(user, params \\ %{}), to: Submissions
  defdelegate get_submission(account_id, block_id, cohort_id \\ nil), to: Submissions

  def create_submission(user, attrs) do
    Submissions.create_submission(user, attrs)
    |> notify_submission_subscribers()
  end

  def update_submission(user, submission, attrs) do
    Submissions.update_submission(user, submission, attrs)
    |> notify_submission_subscribers()
  end

  def system_update_submission(submission, attrs) do
    Submissions.system_update_submission(submission, attrs)
    |> notify_submission_subscribers()
  end

  defdelegate get_latest_submissions(account_id, block_ids, cohort_id \\ nil), to: Submissions
  defdelegate get_submission!(user, id), to: Submissions
  defdelegate get_team_leaderboard(course_id), to: Submissions
  defdelegate delete_submission_with_rollback(user, submission), to: Submissions
  defdelegate count_attempts(account_id, block_ids, cohort_id), to: Submissions
  defdelegate save_draft(user, block_id, content, cohort_id \\ nil), to: Submissions
  defdelegate get_draft(user_id, block_id, cohort_id \\ nil), to: Submissions
  defdelegate clear_draft(user_id, block_id, cohort_id \\ nil), to: Submissions
  defdelegate enqueue_code_execution(submission), to: Submissions
  defdelegate test_code(user, block, code), to: Submissions

  defdelegate start_exam_submission(account_id, exam_block_id, cohort_id, time_limit_seconds),
    to: Submissions

  @doc """
  Saves a question submission and broadcasts the update via PubSub
  for real-time grading monitoring.
  """
  def save_question_submission(
        parent_submission,
        account_id,
        question_block_id,
        cohort_id,
        answer_content
      ) do
    Submissions.save_question_submission(
      parent_submission,
      account_id,
      question_block_id,
      cohort_id,
      answer_content
    )
    |> notify_submission_subscribers()
  end

  defdelegate get_active_exam_submission(account_id, exam_block_id), to: Submissions
  defdelegate get_child_submissions(parent_submission_id), to: Submissions

  @doc """
  Gets an active exam attempt or creates a new one,
  and broadcasts the result so the Grading dashboard updates in real-time.
  """
  def get_or_create_exam_attempt(
        account_id,
        exam_block_id,
        cohort_id,
        time_limit_sec,
        exam_config
      ) do
    Submissions.get_or_create_exam_attempt(
      account_id,
      exam_block_id,
      cohort_id,
      time_limit_sec,
      exam_config
    )
    |> notify_submission_subscribers()
  end

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

  defdelegate subscribe_to_draft_updates(cohort_id, block_id), to: DraftCache

  defp notify_submission_subscribers({:ok, submission} = result) do
    Phoenix.PubSub.broadcast(
      Athena.PubSub,
      "submission:#{submission.account_id}:#{submission.block_id}",
      {:submission_updated, submission}
    )

    if submission.status != :draft do
      Phoenix.PubSub.broadcast(
        Athena.PubSub,
        "grading:updates",
        {:submission_changed, submission}
      )
    end

    result
  end

  defp notify_submission_subscribers(result), do: result
end
