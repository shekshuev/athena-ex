defmodule Athena.Learning.Schedules do
  @moduledoc """
  Business logic for managing cohort-specific content schedules (Overrides).
  """
  import Ecto.Query
  alias Athena.Repo
  alias Athena.Learning.{CohortSchedule, CohortMembership}

  @doc """
  Retrieves all schedule overrides for a specific student in a specific course.
  Used by the Player and Policy engine.
  """
  @spec get_student_overrides(String.t(), String.t(), String.t() | nil) :: [CohortSchedule.t()]

  def get_student_overrides(_account_id, _course_id, nil), do: []

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
  Uses PostgreSQL UPSERT (on_conflict) for atomic updates.
  """
  def set_override(attrs) do
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
  end

  @doc """
  Removes an override, falling back to the global AccessRules.
  """
  @spec clear_override(String.t(), atom() | String.t(), String.t()) :: {integer(), nil | [term()]}
  def clear_override(cohort_id, resource_type, resource_id) do
    res_type_str = to_string(resource_type)

    from(cs in CohortSchedule,
      where:
        cs.cohort_id == ^cohort_id and
          cs.resource_type == ^res_type_str and
          cs.resource_id == ^resource_id
    )
    |> Repo.delete_all()
  end
end
