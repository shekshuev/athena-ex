defmodule Athena.Learning.Instructors do
  @moduledoc """
  Internal business logic for Instructor management.

  Handles CRUD operations for `Instructor` profiles and enriches them
  with user account data from the `Athena.Identity` context.
  """

  import Ecto.Query
  alias Athena.Repo
  alias Athena.Learning.Instructor
  alias Athena.Identity

  @doc """
  Retrieves a paginated list of instructors, scoped by user permissions.
  """
  @spec list_instructors(map(), map()) ::
          {:ok, {[Instructor.t()], Flop.Meta.t()}} | {:error, Flop.Meta.t()}
  def list_instructors(user, params \\ %{}) do
    base_query =
      from(i in Instructor)
      |> Athena.Identity.scope_query(user, "instructors.read")

    case Flop.validate_and_run(base_query, params, for: Instructor) do
      {:ok, {instructors, meta}} ->
        {:ok, {enrich_with_accounts(instructors), meta}}

      error ->
        error
    end
  end

  @doc """
  Searches for instructors by their title or their associated account login.
  Requires 'instructors.read' permission.
  """
  @spec search_instructors(map(), String.t(), integer()) :: [Instructor.t()]
  def search_instructors(user, search_query, limit \\ 10) do
    if Identity.can?(user, "instructors.read") do
      search_term = "%#{search_query}%"

      instructors_by_title =
        Instructor
        |> where([i], ilike(i.title, ^search_term))
        |> limit(^limit)
        |> Repo.all()

      account_ids_from_login =
        Identity.search_accounts_by_login(user, search_query, limit) |> Enum.map(& &1.id)

      instructors_by_account =
        if account_ids_from_login == [] do
          []
        else
          Instructor
          |> where([i], i.owner_id in ^account_ids_from_login)
          |> limit(^limit)
          |> Repo.all()
        end

      (instructors_by_title ++ instructors_by_account)
      |> Enum.uniq_by(& &1.id)
      |> Enum.take(limit)
      |> enrich_with_accounts()
    else
      []
    end
  end

  @doc """
  Retrieves a single instructor, scoped by ACL.
  """
  def get_instructor(user, id) do
    Instructor
    |> where([i], i.id == ^id)
    |> Athena.Identity.scope_query(user, "instructors.read")
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      instructor -> {:ok, enrich_with_accounts(instructor)}
    end
  end

  @doc """
  Creates a new instructor profile.
  """
  @spec create_instructor(map(), map()) ::
          {:ok, Instructor.t()} | {:error, Ecto.Changeset.t() | atom()}
  def create_instructor(user, attrs) do
    if Identity.can?(user, "instructors.create") do
      %Instructor{}
      |> Instructor.changeset(attrs)
      |> Repo.insert()
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Updates an existing instructor profile.
  """
  @spec update_instructor(map(), Instructor.t(), map()) ::
          {:ok, Instructor.t()} | {:error, Ecto.Changeset.t() | atom()}
  def update_instructor(user, %Instructor{} = instructor, attrs) do
    if Identity.can?(user, "instructors.update", instructor) do
      instructor
      |> Instructor.changeset(attrs)
      |> Repo.update()
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Deletes an instructor profile.
  """
  @spec delete_instructor(map(), Instructor.t()) ::
          {:ok, Instructor.t()} | {:error, Ecto.Changeset.t() | atom()}
  def delete_instructor(user, %Instructor{} = instructor) do
    if Identity.can?(user, "instructors.delete", instructor) do
      Repo.delete(instructor)
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Enriches a single instructor or a list of instructors with Account data.
  This function is public so it can be reused by the `Cohorts` context.
  """
  @spec enrich_with_accounts(Instructor.t() | [Instructor.t()]) ::
          Instructor.t() | [Instructor.t()]
  def enrich_with_accounts(%Instructor{} = instructor) do
    [enriched] = enrich_with_accounts([instructor])
    enriched
  end

  def enrich_with_accounts([]), do: []

  def enrich_with_accounts(instructors) when is_list(instructors) do
    account_ids = Enum.map(instructors, & &1.owner_id) |> Enum.uniq()

    accounts_map = Identity.get_accounts_map(account_ids)

    Enum.map(instructors, fn inst ->
      %{inst | account: Map.get(accounts_map, inst.owner_id)}
    end)
  end
end
