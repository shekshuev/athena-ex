defmodule Athena.Learning.Enrollments do
  @moduledoc """
  Business logic for managing course enrollments.

  Handles assigning entire cohorts (or potentially individual students) 
  to courses. Delegates data enrichment (fetching course details and 
  account info) to the `Athena.Content` and `Athena.Identity` contexts.
  """

  import Ecto.Query
  alias Athena.Repo
  alias Athena.Learning.Enrollment
  alias Athena.Content
  alias Athena.Identity

  @doc """
  Retrieves a paginated list of enrollments for a specific cohort.

  Enriches the resulting enrollments with `Course` and `Account` data 
  from their respective contexts.

  ## Parameters
    * `cohort_id` - The ID of the cohort.
    * `params` - A map containing Flop parameters for pagination.
  """
  @spec list_cohort_enrollments(String.t(), map()) ::
          {:ok, {[Enrollment.t()], Flop.Meta.t()}} | {:error, Flop.Meta.t()}
  def list_cohort_enrollments(cohort_id, params \\ %{}) do
    case Enrollment
         |> where(cohort_id: ^cohort_id)
         |> Flop.validate_and_run(params, for: Enrollment) do
      {:ok, {enrollments, meta}} ->
        {:ok, {enrich_enrollments(enrollments), meta}}

      error ->
        error
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
