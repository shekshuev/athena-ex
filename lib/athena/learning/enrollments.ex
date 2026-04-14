defmodule Athena.Learning.Enrollments do
  @moduledoc """
  Business logic for managing course enrollments.

  Handles assigning entire cohorts (or potentially individual students) 
  to courses. Delegates data enrichment (fetching course details and 
  account info) to the `Athena.Content` and `Athena.Identity` contexts.
  """

  import Ecto.Query
  alias Athena.Repo
  alias Athena.Learning.{Enrollment, CohortMembership, CohortInstructor, Instructor}
  alias Athena.Content
  alias Athena.Identity

  @doc """
  Retrieves a paginated list of enrollments for a specific cohort, scoped by user.
  """
  @spec list_cohort_enrollments(map(), String.t(), map()) ::
          {:ok, {[Enrollment.t()], Flop.Meta.t()}} | {:error, Flop.Meta.t()}
  def list_cohort_enrollments(user, cohort_id, params \\ %{}) do
    base_query =
      Enrollment
      |> where(cohort_id: ^cohort_id)
      |> scope_enrollments(user, "enrollments.read")

    case Flop.validate_and_run(base_query, params, for: Enrollment) do
      {:ok, {enrollments, meta}} ->
        {:ok, {enrich_enrollments(enrollments), meta}}

      error ->
        error
    end
  end

  @doc false
  defp scope_enrollments(query, user, permission) do
    cond do
      "admin" in user.role.permissions ->
        query

      permission in user.role.permissions ->
        policies = Map.get(user.role.policies || %{}, permission, [])

        if "own_only" in policies do
          my_cohort_ids =
            from ci in CohortInstructor,
              join: i in Instructor,
              on: ci.instructor_id == i.id,
              where: i.owner_id == ^user.id,
              select: ci.cohort_id

          my_course_ids = Content.list_accessible_course_ids(user)

          where(
            query,
            [e],
            e.course_id in ^my_course_ids or e.cohort_id in subquery(my_cohort_ids)
          )
        else
          query
        end

      true ->
        where(query, [e], false)
    end
  end

  @doc """
  Gets a specific enrollment by ID.

  Preloads the associated `Cohort` and enriches the enrollment with 
  `Course` and `Account` data. Raises `Ecto.NoResultsError` if not found.
  """
  @spec get_enrollment!(String.t()) :: Enrollment.t()
  def get_enrollment!(id) do
    Enrollment
    |> preload(:cohort)
    |> Repo.get!(id)
    |> enrich_enrollments()
  end

  @doc """
  Assigns an entire cohort to a course.

  Defaults to an `:active` status. Enforces unique constraints 
  (a cohort cannot be enrolled in the same course twice).
  """
  @spec enroll_cohort(String.t(), String.t(), atom()) ::
          {:ok, Enrollment.t()} | {:error, Ecto.Changeset.t()}
  def enroll_cohort(cohort_id, course_id, status \\ :active) do
    %Enrollment{}
    |> Enrollment.changeset(%{cohort_id: cohort_id, course_id: course_id, status: status})
    |> Repo.insert()
  end

  @doc """
  Updates an enrollment's attributes (e.g., changing status from :active to :dropped).
  """
  @spec update_enrollment(Enrollment.t(), map()) ::
          {:ok, Enrollment.t()} | {:error, Ecto.Changeset.t()}
  def update_enrollment(%Enrollment{} = enrollment, attrs) do
    enrollment
    |> Enrollment.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Revokes access completely by permanently deleting the enrollment record.
  """
  @spec delete_enrollment(Enrollment.t()) ::
          {:ok, Enrollment.t()} | {:error, Ecto.Changeset.t()}
  def delete_enrollment(%Enrollment{} = enrollment) do
    Repo.delete(enrollment)
  end

  @doc """
  Retrieves all active course enrollments for a specific student.
  Includes both direct enrollments (by account_id) and cohort-based enrollments.
  Filters out duplicates and soft-deleted courses.
  """
  @spec list_student_enrollments(String.t()) :: [Enrollment.t()]
  def list_student_enrollments(account_id) do
    cohort_ids_query =
      from cm in CohortMembership,
        where: cm.account_id == ^account_id,
        select: cm.cohort_id

    Enrollment
    |> where([e], e.account_id == ^account_id or e.cohort_id in subquery(cohort_ids_query))
    |> where([e], e.status != :dropped)
    |> distinct([e], e.course_id)
    |> Repo.all()
    |> enrich_enrollments()
    |> Enum.reject(&is_nil(&1.course))
  end

  @doc """
  Fast check if a student has active access to a course 
  (either directly or via any of their cohorts).
  """
  @spec has_access?(String.t(), String.t()) :: boolean()
  def has_access?(account_id, course_id) do
    cohort_ids_query =
      from cm in CohortMembership,
        where: cm.account_id == ^account_id,
        select: cm.cohort_id

    Enrollment
    |> where([e], e.course_id == ^course_id)
    |> where([e], e.account_id == ^account_id or e.cohort_id in subquery(cohort_ids_query))
    |> where([e], e.status != :dropped)
    |> Repo.exists?()
  end

  @doc false
  defp enrich_enrollments(%Enrollment{} = enrollment) do
    [enriched] = enrich_enrollments([enrollment])
    enriched
  end

  defp enrich_enrollments([]), do: []

  defp enrich_enrollments(enrollments) do
    account_ids = Enum.map(enrollments, & &1.account_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    course_ids = Enum.map(enrollments, & &1.course_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    accounts_map = if account_ids == [], do: %{}, else: Identity.get_accounts_map(account_ids)
    courses_map = if course_ids == [], do: %{}, else: Content.get_courses_map(course_ids)

    Enum.map(enrollments, fn enrollment ->
      %{
        enrollment
        | account: Map.get(accounts_map, enrollment.account_id),
          course: Map.get(courses_map, enrollment.course_id)
      }
    end)
  end
end
