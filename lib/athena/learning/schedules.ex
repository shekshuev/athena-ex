defmodule Athena.Learning.Schedules do
  @moduledoc """
  Business logic for managing cohort-specific content schedules (Overrides).
  """
  import Ecto.Query
  alias Athena.{Repo, Identity}
  alias Athena.Learning.{CohortSchedule, CohortMembership}

  @doc """
  Retrieves all schedule overrides for a specific student in a specific course.
  Used by the Player and Policy engine.
  """
  @spec get_student_overrides(String.t(), String.t(), String.t() | nil) :: [CohortSchedule.t()]

  def get_student_overrides(_account_id, _course_id, cohort_id) when cohort_id in [nil, ""],
    do: []

  def get_student_overrides(account_id, course_id, cohort_id) do
    cohort_ids_query =
      from cm in CohortMembership,
        where: cm.account_id == ^account_id and cm.cohort_id == ^cohort_id,
        select: cm.cohort_id

    Repo.all(
      from cs in CohortSchedule,
        where: cs.course_id == ^course_id and cs.cohort_id in subquery(cohort_ids_query)
    )
  end

  @doc """
  Retrieves all overrides for a specific cohort and course.
  Used by the Instructor UI to show badges in the course tree.
  """
  @spec list_cohort_course_overrides(String.t(), String.t()) :: [CohortSchedule.t()]
  def list_cohort_course_overrides(cohort_id, course_id) do
    Repo.all(
      from cs in CohortSchedule,
        where: cs.cohort_id == ^cohort_id and cs.course_id == ^course_id
    )
  end

  @doc """
  Creates or updates an override for a specific resource.
  Enforces ACL: user must have rights to manage the cohort or the course.
  """
  def set_override(user, cohort, course, attrs) do
    if can_manage_schedule?(user, cohort, course) do
      %CohortSchedule{}
      |> CohortSchedule.changeset(attrs)
      |> Repo.insert(
        on_conflict: [
          set: [
            unlock_at: Map.get(attrs, "unlock_at") || Map.get(attrs, :unlock_at),
            lock_at: Map.get(attrs, "lock_at") || Map.get(attrs, :lock_at),
            visibility: Map.get(attrs, "visibility") || Map.get(attrs, :visibility),
            updated_at: DateTime.utc_now()
          ]
        ],
        conflict_target: [:cohort_id, :resource_id, :resource_type]
      )
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Removes an override, falling back to the global AccessRules.
  Enforces ACL.
  """
  @spec clear_override(map(), map(), map(), atom() | String.t(), String.t()) ::
          {:ok, {integer(), nil | [term()]}} | {:error, :unauthorized}
  def clear_override(user, cohort, course, resource_type, resource_id) do
    if can_manage_schedule?(user, cohort, course) do
      res_type_str = to_string(resource_type)

      result =
        from(cs in CohortSchedule,
          where:
            cs.cohort_id == ^cohort.id and
              cs.resource_type == ^res_type_str and
              cs.resource_id == ^resource_id
        )
        |> Repo.delete_all()

      {:ok, result}
    else
      {:error, :unauthorized}
    end
  end

  @doc false
  defp can_manage_schedule?(user, cohort, course) do
    if Identity.can?(user, "enrollments.update") do
      policies = Map.get(user.role.policies || %{}, "enrollments.update", [])

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
end
