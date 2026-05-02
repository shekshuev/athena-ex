defmodule Athena.Learning.Enrollments do
  @moduledoc """
  Business logic for managing course enrollments.

  Handles assigning entire cohorts (or potentially individual students) 
  to courses. Delegates data enrichment (fetching course details and 
  account info) to the `Athena.Content` and `Athena.Identity` contexts.
  """

  import Ecto.Query
  alias Athena.Repo

  alias Athena.Learning.{
    Enrollment,
    CohortMembership,
    CohortInstructor,
    Instructor,
    Cohorts,
    Cohort
  }

  alias Athena.{Content, Identity}

  use Gettext, backend: AthenaWeb.Gettext

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
  Gets a specific enrollment by ID safely based on user scope.
  """
  @spec get_enrollment!(map(), String.t()) :: Enrollment.t()
  def get_enrollment!(user, id) do
    Enrollment
    |> scope_enrollments(user, "enrollments.read")
    |> preload(:cohort)
    |> Repo.get!(id)
    |> enrich_enrollments()
  end

  @doc """
  Assigns an entire cohort to a course.
  Enforces type matching and uses context functions to verify ACL on both the Cohort and the Course.
  """
  @spec enroll_cohort(map(), String.t(), String.t(), atom()) ::
          {:ok, Enrollment.t()} | {:error, String.t() | Ecto.Changeset.t() | atom()}
  def enroll_cohort(user, cohort_id, course_id, status \\ :active) do
    with {:ok, cohort} <- Cohorts.get_cohort(user, cohort_id),
         {:ok, course} <- Content.get_course(user, course_id) do
      if can_create_enrollment?(user, cohort, course) do
        insert_if_types_match(cohort, course, status)
      else
        {:error, :unauthorized}
      end
    else
      {:error, :not_found} ->
        {:error, gettext("Cohort or Course not found or access denied.")}
    end
  end

  @doc """
  Checks if a user can create an enrollment for a specific cohort and course.
  For 'own_only' policies, they must own either the cohort or the course.
  """
  def can_create_enrollment?(user, cohort, course) do
    if Identity.can?(user, "enrollments.create") do
      policies = Map.get(user.role.policies || %{}, "enrollments.create", [])

      if "own_only" in policies do
        Identity.can?(user, "cohorts.update", cohort) or
          Identity.can?(user, "courses.update", course)
      else
        true
      end
    else
      false
    end
  end

  @doc false
  defp insert_if_types_match(cohort, course, status) do
    cond do
      cohort.type == :team and course.type != :competition ->
        {:error, gettext("Cannot assign a Competition Team to a Standard Course.")}

      cohort.type == :academic and course.type != :standard ->
        {:error, gettext("Cannot assign an Academic Group to a Competition.")}

      true ->
        %Enrollment{}
        |> Enrollment.changeset(%{cohort_id: cohort.id, course_id: course.id, status: status})
        |> Repo.insert()
    end
  end

  @doc """
  Updates an enrollment's attributes.
  """
  @spec update_enrollment(map(), Enrollment.t(), map()) ::
          {:ok, Enrollment.t()} | {:error, Ecto.Changeset.t() | atom()}
  def update_enrollment(user, %Enrollment{} = enrollment, attrs) do
    if can_manage_enrollment?(user, "enrollments.update", enrollment) do
      enrollment
      |> Enrollment.changeset(attrs)
      |> Repo.update()
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Revokes access completely by permanently deleting the enrollment record.
  """
  @spec delete_enrollment(map(), Enrollment.t()) ::
          {:ok, Enrollment.t()} | {:error, Ecto.Changeset.t() | atom()}
  def delete_enrollment(user, %Enrollment{} = enrollment) do
    if can_manage_enrollment?(user, "enrollments.delete", enrollment) do
      Repo.delete(enrollment)
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Retrieves all active course enrollments for a specific student.
  Includes both direct enrollments and cohort-based enrollments.
  ONLY RETURNS PUBLISHED COURSES.
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
    |> preload(:cohort)
    |> Repo.all()
    |> enrich_enrollments()
    |> Enum.reject(fn e -> is_nil(e.course) or e.course.status != :published end)
  end

  @doc """
  Fast check if a student has active access to a course.
  """
  @spec has_access?(String.t(), String.t()) :: boolean()
  def has_access?(account_id, course_id) do
    case Content.get_course(course_id) do
      {:ok, %{status: :published}} ->
        cohort_ids_query =
          from cm in CohortMembership,
            where: cm.account_id == ^account_id,
            select: cm.cohort_id

        Enrollment
        |> where([e], e.course_id == ^course_id)
        |> where([e], e.account_id == ^account_id or e.cohort_id in subquery(cohort_ids_query))
        |> where([e], e.status != :dropped)
        |> Repo.exists?()

      _ ->
        false
    end
  end

  @doc """
  Checks if a user can manage (update/delete) an enrollment.
  For 'own_only' policies, the user must own either the associated cohort or the course.
  Takes an optional preloaded `cohort` to prevent N+1 queries in UI lists.
  """
  def can_manage_enrollment?(user, action, %Enrollment{} = enrollment, preloaded_cohort \\ nil) do
    if Identity.can?(user, action) do
      policies = Map.get(user.role.policies || %{}, action, [])

      if "own_only" in policies do
        check_own_only_policy(user, enrollment, preloaded_cohort)
      else
        true
      end
    else
      false
    end
  end

  defp check_own_only_policy(user, enrollment, preloaded_cohort) do
    owns_cohort?(user, enrollment, preloaded_cohort) or owns_course?(user, enrollment)
  end

  defp owns_cohort?(user, enrollment, preloaded_cohort) do
    cohort =
      preloaded_cohort || enrollment.cohort ||
        Repo.get(Cohort, enrollment.cohort_id)

    cohort != nil and Identity.can?(user, "cohorts.update", cohort)
  end

  defp owns_course?(user, enrollment) do
    course = enrollment.course || Repo.get(Course, enrollment.course_id)

    course != nil and Identity.can?(user, "courses.update", course)
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

  @doc """
  Finds the active cohort a user belongs to for a specific course.
  """
  @spec get_user_cohort_for_course(String.t(), String.t()) :: Cohort.t() | nil
  def get_user_cohort_for_course(user_id, course_id) do
    query =
      from c in Cohort,
        join: cm in CohortMembership,
        on: cm.cohort_id == c.id,
        join: e in Enrollment,
        on: e.cohort_id == c.id,
        where: cm.account_id == ^user_id and e.course_id == ^course_id and e.status == :active,
        limit: 1

    Repo.one(query)
  end
end
