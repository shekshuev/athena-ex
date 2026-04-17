defmodule Athena.Learning.Cohorts do
  @moduledoc """
  Internal business logic for Cohort management.

  Handles CRUD operations for `Cohort` and manages the many-to-many
  relationships with `Instructor` and the one-to-many relationships
  with `CohortMembership` (students).
  """

  import Ecto.Query
  alias Athena.Repo
  alias Athena.Learning.{Cohort, Instructor, CohortMembership, Instructors, CohortInstructor}
  alias Athena.Identity

  @doc """
  Retrieves a paginated list of cohorts, scoped by user permissions.
  """
  @spec list_cohorts(map(), map()) ::
          {:ok, {[Cohort.t()], Flop.Meta.t()}} | {:error, Flop.Meta.t()}
  def list_cohorts(user, params \\ %{}) do
    base_query = scope_cohorts(Cohort, user, "cohorts.read")

    case Flop.validate_and_run(base_query, params, for: Cohort) do
      {:ok, {cohorts, meta}} ->
        cohorts = Repo.preload(cohorts, :instructors)
        {:ok, {enrich_cohorts(cohorts), meta}}

      error ->
        error
    end
  end

  @doc false
  defp scope_cohorts(query, user, permission) do
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

          where(query, [c], c.id in subquery(my_cohort_ids))
        else
          query
        end

      true ->
        where(query, [c], false)
    end
  end

  @doc """
  Retrieves a single cohort safely.
  """
  def get_cohort(user, id) do
    Cohort
    |> where([c], c.id == ^id)
    |> scope_cohorts(user, "cohorts.read")
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      cohort -> {:ok, enrich_cohorts(Repo.preload(cohort, :instructors))}
    end
  end

  @doc """
  Gets a single cohort by its ID.
  Raises `Ecto.NoResultsError` if the Cohort does not exist.
  """
  def get_cohort!(id), do: Repo.get!(Cohort, id)

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
