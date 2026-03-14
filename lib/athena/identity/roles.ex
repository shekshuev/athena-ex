defmodule Athena.Identity.Roles do
  @moduledoc """
  Internal business logic for the Role entity.

  Handles CRUD operations for roles, updating permissions/policies, 
  and safely deleting roles while handling foreign key constraints.
  """

  alias Athena.Repo
  alias Athena.Identity.{Role, Account}
  import Ecto.Query

  @doc """
  Retrieves a paginated list of roles using Flop.
  """
  @spec list_roles(map()) :: {:ok, {[Role.t()], Flop.Meta.t()}} | {:error, Flop.Meta.t()}
  def list_roles(params \\ %{}) do
    Flop.validate_and_run(Role, params, for: Role)
  end

  @doc """
  Retrieves all roles without pagination.
  Useful for populating select dropdowns in the UI.
  """
  @spec list_all_roles() :: [Role.t()]
  def list_all_roles do
    Repo.all(Role)
  end

  @doc """
  Retrieves a single role by ID.
  """
  @spec get_role(String.t()) :: {:ok, Role.t()} | {:error, :not_found}
  def get_role(id) do
    case Repo.get(Role, id) do
      nil -> {:error, :not_found}
      role -> {:ok, role}
    end
  end

  @doc """
  Retrieves a role by its unique name.
  """
  @spec get_role_by_name(String.t()) :: {:ok, Role.t()} | {:error, :not_found}
  def get_role_by_name(name) do
    case Repo.get_by(Role, name: name) do
      nil -> {:error, :not_found}
      role -> {:ok, role}
    end
  end

  @doc """
  Creates a new role.
  """
  @spec create_role(map()) :: {:ok, Role.t()} | {:error, Ecto.Changeset.t()}
  def create_role(attrs) do
    %Role{}
    |> Role.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates an existing role.
  """
  @spec update_role(Role.t(), map()) :: {:ok, Role.t()} | {:error, Ecto.Changeset.t()}
  def update_role(%Role{} = role, attrs) do
    role
    |> Role.changeset(attrs)
    |> Repo.update()
    |> case do
      {:ok, updated_role} ->
        clear_accounts_cache_for_role(updated_role.id)
        Phoenix.PubSub.broadcast(Athena.PubSub, "role_updates:#{updated_role.id}", :role_updated)
        {:ok, updated_role}

      error ->
        error
    end
  end

  @doc """
  Deletes a role and schedules an outbox event in a single transaction.

  Returns `{:error, :role_in_use}` if the role is still assigned to accounts.
  """
  @spec delete_role(Role.t()) ::
          {:ok, map()} | {:error, :role_in_use} | {:error, Ecto.Changeset.t()}
  def delete_role(%Role{} = role) do
    Ecto.Multi.new()
    |> Ecto.Multi.delete(:role, role_delete_changeset(role))
    |> Repo.transaction()
    |> case do
      {:ok, result} ->
        {:ok, result}

      {:error, :role, %Ecto.Changeset{} = changeset, _changes} ->
        if has_foreign_key_error?(changeset) do
          {:error, :role_in_use}
        else
          {:error, changeset}
        end
    end
  end

  defp role_delete_changeset(role) do
    role
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.foreign_key_constraint(:accounts, name: :accounts__role_id__fk)
  end

  defp has_foreign_key_error?(changeset) do
    Enum.any?(changeset.errors, fn {field, {_, meta}} ->
      field == :accounts and meta[:constraint] == :foreign
    end)
  end

  defp clear_accounts_cache_for_role(role_id) do
    Account
    |> where([a], a.role_id == ^role_id)
    |> select([a], a.id)
    |> Repo.all()
    |> Enum.each(&Cachex.del(:account_cache, &1))
  end
end
