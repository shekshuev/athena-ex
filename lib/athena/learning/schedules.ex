defmodule Athena.Learning.Schedules do
  @moduledoc """
  Business logic for managing cohort-specific content schedules.
  """
  import Ecto.Query
  alias Athena.Repo
  alias Athena.Learning.{CohortSchedule, CohortMembership}

  @doc """
  Retrieves all schedule overrides for a specific student in a specific course.
  This prevents N+1 queries by fetching all rules upfront for the Policy engine.
  """
  @spec get_student_overrides(String.t(), String.t()) :: [CohortSchedule.t()]
  def get_student_overrides(account_id, course_id) do
    cohort_ids_query =
      from cm in CohortMembership,
        where: cm.account_id == ^account_id,
        select: cm.cohort_id

    Repo.all(
      from cs in CohortSchedule,
        where: cs.course_id == ^course_id and cs.cohort_id in subquery(cohort_ids_query)
    )
  end
end
