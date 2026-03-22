defmodule Athena.Learning.Instructors do
  @moduledoc """
  Internal business logic for Instructor management.
  """

  import Ecto.Query
  alias Athena.Repo
  alias Athena.Learning.Instructor
  alias Athena.Identity

  @doc """
  Retrieves a paginated list of instructors.
  Preloads the associated account to display login/email in the UI.
  """
  @spec list_instructors(map()) ::
          {:ok, {[Instructor.t()], Flop.Meta.t()}} | {:error, Flop.Meta.t()}
  def list_instructors(params \\ %{}) do
    case Flop.validate_and_run(Instructor, params, for: Instructor) do
      {:ok, {instructors, meta}} ->
        {:ok, {enrich_with_accounts(instructors), meta}}

      error ->
        error
    end
  end

  @doc """
  Searches for instructors by their title or their associated account login.
  Useful for autocomplete and multi-select components.
  """
  @spec search_instructors(String.t(), integer()) :: [Instructor.t()]
  def search_instructors(search_query, limit \\ 10) do
    search_term = "%#{search_query}%"

    instructors_by_title =
      Instructor
      |> where([i], ilike(i.title, ^search_term))
      |> limit(^limit)
      |> Repo.all()

    account_ids_from_login =
      Identity.search_accounts_by_login(search_query, limit) |> Enum.map(& &1.id)

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
  end

  @doc """
  Retrieves a single instructor by its ID.
  """
  @spec get_instructor!(String.t()) :: Instructor.t()
  def get_instructor!(id) do
    Repo.get!(Instructor, id)
    |> enrich_with_accounts()
  end

  @doc """
  Creates a new instructor.
  """
  @spec create_instructor(map()) :: {:ok, Instructor.t()} | {:error, Ecto.Changeset.t()}
  def create_instructor(attrs) do
    %Instructor{}
    |> Instructor.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates an existing instructor.
  """
  @spec update_instructor(Instructor.t(), map()) ::
          {:ok, Instructor.t()} | {:error, Ecto.Changeset.t()}
  def update_instructor(%Instructor{} = instructor, attrs) do
    instructor
    |> Instructor.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes an instructor.
  """
  @spec delete_instructor(Instructor.t()) :: {:ok, Instructor.t()} | {:error, Ecto.Changeset.t()}
  def delete_instructor(%Instructor{} = instructor) do
    Repo.delete(instructor)
  end

  def enrich_with_accounts(%Instructor{} = instructor) do
    [enriched] = enrich_with_accounts([instructor])
    enriched
  end

  def enrich_with_accounts([]), do: []

  def enrich_with_accounts(instructors) do
    account_ids = Enum.map(instructors, & &1.owner_id) |> Enum.uniq()

    accounts_map = Identity.get_accounts_map(account_ids)

    Enum.map(instructors, fn inst ->
      %{inst | account: Map.get(accounts_map, inst.owner_id)}
    end)
  end
end
