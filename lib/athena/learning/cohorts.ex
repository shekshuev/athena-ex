defmodule Athena.Learning.Cohorts do
  @moduledoc """
  Internal business logic for Cohort management.

  Handles CRUD operations for `Cohort` and manages the many-to-many
  relationships with `Instructor` and the one-to-many relationships
  with `CohortMembership` (students).
  """

  import Ecto.Query
  alias Athena.Repo
  alias Athena.Learning.{Cohort, Instructor, CohortMembership, Instructors}
  alias Athena.Identity

  @doc """
  Retrieves a paginated list of cohorts.

  Preloads associated instructors and enriches them with Identity context data.

  ## Parameters
    * `params` - A map containing Flop parameters for pagination and filtering.
  """
  @spec list_cohorts(map()) :: {:ok, {[Cohort.t()], Flop.Meta.t()}} | {:error, Flop.Meta.t()}
  def list_cohorts(params \\ %{}) do
    case Flop.validate_and_run(Cohort, params, for: Cohort) do
      {:ok, {cohorts, meta}} ->
        cohorts = Repo.preload(cohorts, :instructors)
        {:ok, {enrich_cohorts(cohorts), meta}}

      error ->
        error
    end
  end

  @doc """
  Retrieves a single cohort by its ID.

  Preloads associated instructors and enriches them.
  Raises `Ecto.NoResultsError` if the cohort does not exist.
  """
  @spec get_cohort!(String.t()) :: Cohort.t()
  def get_cohort!(id) do
    Cohort
    |> Repo.get!(id)
    |> Repo.preload(:instructors)
    |> enrich_cohorts()
  end

  @doc """
  Creates a new cohort.

  Optionally accepts a list of instructor IDs in `instructor_ids` to assign them immediately.
  """
  @spec create_cohort(map()) :: {:ok, Cohort.t()} | {:error, Ecto.Changeset.t()}
  def create_cohort(attrs) do
    %Cohort{}
    |> Repo.preload(:instructors)
    |> Cohort.changeset(attrs)
    |> put_instructors(attrs["instructor_ids"] || attrs[:instructor_ids])
    |> Repo.insert()
  end

  @doc """
  Updates an existing cohort.

  If `instructor_ids` is provided, it completely replaces the current list of instructors.
  """
  @spec update_cohort(Cohort.t(), map()) :: {:ok, Cohort.t()} | {:error, Ecto.Changeset.t()}
  def update_cohort(%Cohort{} = cohort, attrs) do
    cohort
    |> Repo.preload(:instructors)
    |> Cohort.changeset(attrs)
    |> put_instructors(attrs["instructor_ids"] || attrs[:instructor_ids])
    |> Repo.update()
  end

  @doc """
  Deletes a cohort.
  """
  @spec delete_cohort(Cohort.t()) :: {:ok, Cohort.t()} | {:error, Ecto.Changeset.t()}
  def delete_cohort(%Cohort{} = cohort) do
    Repo.delete(cohort)
  end

  @doc false
  defp put_instructors(changeset, nil), do: changeset

  defp put_instructors(changeset, ids) when is_list(ids) do
    clean_ids = Enum.reject(ids, &(&1 == ""))
    instructors = Repo.all(from i in Instructor, where: i.id in ^clean_ids)
    Ecto.Changeset.put_assoc(changeset, :instructors, instructors)
  end

  @doc """
  Retrieves a paginated list of students enrolled in a specific cohort.

  Enriches the memberships with Account data from the Identity context.
  """
  @spec list_cohort_memberships(String.t(), map()) ::
          {:ok, {[CohortMembership.t()], Flop.Meta.t()}} | {:error, Flop.Meta.t()}
  def list_cohort_memberships(cohort_id, params \\ %{}) do
    case CohortMembership
         |> where(cohort_id: ^cohort_id)
         |> Flop.validate_and_run(params, for: CohortMembership) do
      {:ok, {memberships, meta}} ->
        {:ok, {enrich_memberships_with_accounts(memberships), meta}}

      error ->
        error
    end
  end

  @doc """
  Gets a specific cohort membership by ID.

  Enriches the membership with Account data.
  """
  @spec get_cohort_membership!(String.t()) :: CohortMembership.t()
  def get_cohort_membership!(id) do
    Repo.get!(CohortMembership, id)
    |> enrich_memberships_with_accounts()
  end

  @doc """
  Adds a student account to a cohort.
  """
  @spec add_student_to_cohort(String.t(), String.t()) ::
          {:ok, CohortMembership.t()} | {:error, Ecto.Changeset.t()}
  def add_student_to_cohort(cohort_id, account_id) do
    %CohortMembership{}
    |> CohortMembership.changeset(%{cohort_id: cohort_id, account_id: account_id})
    |> Repo.insert()
  end

  @doc """
  Removes a student account from a cohort.
  """
  @spec remove_student_from_cohort(CohortMembership.t()) ::
          {:ok, CohortMembership.t()} | {:error, Ecto.Changeset.t()}
  def remove_student_from_cohort(%CohortMembership{} = membership) do
    Repo.delete(membership)
  end

  @doc false
  defp enrich_memberships_with_accounts(%CohortMembership{} = membership) do
    [enriched] = enrich_memberships_with_accounts([membership])
    enriched
  end

  defp enrich_memberships_with_accounts([]), do: []

  defp enrich_memberships_with_accounts(memberships) do
    account_ids = Enum.map(memberships, & &1.account_id) |> Enum.uniq()
    accounts_map = Identity.get_accounts_map(account_ids)

    Enum.map(memberships, fn membership ->
      %{membership | account: Map.get(accounts_map, membership.account_id)}
    end)
  end

  @doc false
  defp enrich_cohorts(%Cohort{} = cohort) do
    %{cohort | instructors: Instructors.enrich_with_accounts(cohort.instructors)}
  end

  defp enrich_cohorts(cohorts) when is_list(cohorts) do
    Enum.map(cohorts, fn cohort ->
      %{cohort | instructors: Instructors.enrich_with_accounts(cohort.instructors)}
    end)
  end
end
