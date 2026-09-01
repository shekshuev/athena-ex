defmodule Athena.Learning.Enrollments do
  @moduledoc """
  Business logic for managing course enrollments.

  Handles assigning entire cohorts to courses. Access is governed by
  whether the user has teaching rights in the associated cohort.
  """

  import Ecto.Query
  alias Athena.Repo

  alias Athena.Learning.{
    Enrollment,
    CohortMembership,
    CohortInstructor,
    Instructor,
    Cohorts,
    Cohort,
    Content
  }

  alias Athena.{Content, Identity}

  use Gettext, backend: AthenaWeb.Gettext

  @doc """
  Retrieves a paginated list of enrollments for a specific cohort.
  """
  def list_cohort_enrollments(user, cohort_id, params \\ %{}) do
    base_query =
      Enrollment
      |> where(cohort_id: ^cohort_id)
      |> scope_enrollments(user)

    case Flop.validate_and_run(base_query, params, for: Enrollment) do
      {:ok, {enrollments, meta}} ->
        {:ok, {enrich_enrollments(enrollments), meta}}

      error ->
        error
    end
  end

  @doc false
  defp scope_enrollments(query, user) do
    if "admin" in user.role.permissions do
      query
    else
      my_cohort_ids =
        from c in Cohort,
          left_join: ci in CohortInstructor,
          on: ci.cohort_id == c.id,
          left_join: i in Instructor,
          on: ci.instructor_id == i.id,
          where: c.owner_id == ^user.id or i.owner_id == ^user.id,
          select: c.id

      my_course_ids = Content.list_accessible_course_ids(user)

      where(
        query,
        [e],
        e.course_id in ^my_course_ids or e.cohort_id in subquery(my_cohort_ids)
      )
    end
  end

  @doc """
  Gets a specific enrollment by ID safely based on user scope.
  """
  def get_enrollment!(user, id) do
    Enrollment
    |> scope_enrollments(user)
    |> preload(:cohort)
    |> Repo.get!(id)
    |> enrich_enrollments()
  end

  @doc """
  Assigns an entire cohort to a course.
  """
  def enroll_cohort(user, cohort_id, course_id, status \\ :active) do
    with {:ok, cohort} <- Cohorts.get_cohort(user, cohort_id),
         {:ok, course} <- Content.get_course(course_id) do
      if Cohorts.can_manage_cohort_processes?(user, cohort) and
           Content.can_edit_course?(user, course) do
        insert_if_types_match(cohort, course, status)
      else
        {:error, :forbidden}
      end
    else
      {:error, :not_found} ->
        {:error, gettext("Cohort or Course not found or access denied.")}
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
        case check_student_overlap(cohort.id, course.id) do
          [] ->
            %Enrollment{}
            |> Enrollment.changeset(%{cohort_id: cohort.id, course_id: course.id, status: status})
            |> Repo.insert()

          overlapping_students ->
            logins =
              overlapping_students
              |> Enum.map_join(", ", & &1.login)

            {:error,
             dgettext(
               "errors",
               "Cannot enroll: the following students already have access to this course: %{logins}",
               logins: logins
             )}
        end
    end
  end

  @doc false
  defp check_student_overlap(cohort_id, course_id) do
    case fetch_cohort_student_ids(cohort_id) do
      [] ->
        []

      student_ids ->
        student_ids
        |> find_all_overlaps(course_id, cohort_id)
        |> fetch_overlapping_accounts()
    end
  end

  @doc false
  defp fetch_cohort_student_ids(cohort_id) do
    from(cm in CohortMembership,
      where: cm.cohort_id == ^cohort_id,
      select: cm.account_id
    )
    |> Repo.all()
  end

  @doc false
  defp find_all_overlaps(student_ids, course_id, cohort_id) do
    individual = find_individual_overlaps(student_ids, course_id)
    via_cohorts = find_cohort_overlaps(student_ids, course_id, cohort_id)

    Enum.uniq(individual ++ via_cohorts)
  end

  @doc false
  defp find_individual_overlaps(student_ids, course_id) do
    from(e in Enrollment,
      where:
        e.course_id == ^course_id and
          e.account_id in ^student_ids and
          e.status != :dropped,
      select: e.account_id
    )
    |> Repo.all()
  end

  @doc false
  defp find_cohort_overlaps(student_ids, course_id, current_cohort_id) do
    other_cohort_ids =
      from(e in Enrollment,
        where:
          e.course_id == ^course_id and
            e.status != :dropped and
            not is_nil(e.cohort_id) and
            e.cohort_id != ^current_cohort_id,
        select: e.cohort_id,
        distinct: true
      )
      |> Repo.all()

    case other_cohort_ids do
      [] ->
        []

      ids ->
        from(cm in CohortMembership,
          where: cm.cohort_id in ^ids and cm.account_id in ^student_ids,
          select: cm.account_id
        )
        |> Repo.all()
    end
  end

  @doc false
  defp fetch_overlapping_accounts([]), do: []

  defp fetch_overlapping_accounts(ids) do
    from(a in Athena.Identity.Account, where: a.id in ^ids)
    |> Repo.all()
  end

  @doc """
  Enrolls a single student account into a course, independent of any cohort.
  """
  def enroll_account(user, account_id, course_id, status \\ :active) do
    with {:ok, course} <- Content.get_course(course_id) do
      if Content.can_edit_course?(user, course) do
        insert_account_if_type_matches(account_id, course, status)
      else
        {:error, :forbidden}
      end
    else
      {:error, :not_found} ->
        {:error, gettext("Course not found or access denied.")}
    end
  end

  @doc false
  defp insert_account_if_type_matches(account_id, course, status) do
    if course.type != :standard do
      {:error, gettext("Cannot individually enroll a student into a Competition course.")}
    else
      case check_account_overlap(account_id, course.id) do
        nil ->
          %Enrollment{}
          |> Enrollment.changeset(%{account_id: account_id, course_id: course.id, status: status})
          |> Repo.insert()

        cohort ->
          {:error,
           dgettext(
             "errors",
             "Cannot enroll: the student already has access to this course via the group \"%{name}\".",
             name: cohort.name
           )}
      end
    end
  end

  @doc false
  defp check_account_overlap(account_id, course_id) do
    cohort_ids_query =
      from(cm in CohortMembership,
        where: cm.account_id == ^account_id,
        select: cm.cohort_id
      )

    from(e in Enrollment,
      join: c in Cohort,
      on: c.id == e.cohort_id,
      where:
        e.course_id == ^course_id and
          e.status != :dropped and
          e.cohort_id in subquery(cohort_ids_query),
      select: c,
      limit: 1
    )
    |> Repo.one()
  end

  @doc """
  Updates an enrollment's attributes.
  """
  def update_enrollment(user, %Enrollment{} = enrollment, attrs) do
    if can_manage_enrollment?(user, enrollment) do
      enrollment
      |> Enrollment.changeset(attrs)
      |> Repo.update()
    else
      {:error, :forbidden}
    end
  end

  @doc """
  Revokes access completely by permanently deleting the enrollment record.
  """
  def delete_enrollment(user, %Enrollment{} = enrollment) do
    if can_manage_enrollment?(user, enrollment) do
      Repo.delete(enrollment)
    else
      {:error, :forbidden}
    end
  end

  @doc false
  defp can_manage_enrollment?(user, %Enrollment{cohort_id: cohort_id})
       when not is_nil(cohort_id) do
    cohort = Repo.get(Cohort, cohort_id)
    Cohorts.can_manage_cohort_processes?(user, cohort)
  end

  defp can_manage_enrollment?(user, %Enrollment{course_id: course_id}) do
    case Content.get_course(course_id) do
      {:ok, course} -> Content.can_edit_course?(user, course)
      _ -> false
    end
  end

  @doc """
  Lists individual (non-cohort) enrollments for a course.
  """
  def list_account_enrollments(course_id) do
    Enrollment
    |> where([e], e.course_id == ^course_id and not is_nil(e.account_id))
    |> Repo.all()
    |> enrich_enrollments()
  end

  @doc """
  Retrieves all active course enrollments for a specific student.
  ONLY RETURNS PUBLISHED COURSES.
  """
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
