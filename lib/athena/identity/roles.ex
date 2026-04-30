defmodule Athena.Identity.Roles do
  @moduledoc """
  Internal business logic for the Role entity.

  Handles CRUD operations for roles, updating permissions/policies, 
  and safely deleting roles while handling foreign key constraints.
  """

  alias Athena.Repo
  alias Athena.Identity.{Role, Account, Acl}
  import Ecto.Query

  @doc """
  Retrieves a paginated list of roles using Flop.
  """
  @spec list_roles(map(), map()) :: {:ok, {[Role.t()], Flop.Meta.t()}} | {:error, Flop.Meta.t()}
  def list_roles(user, params \\ %{}) do
    if Acl.can?(user, "roles.read") do
      Flop.validate_and_run(Role, params, for: Role)
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Retrieves all roles without pagination.
  Useful for populating select dropdowns in the UI.
  """
  @spec list_all_roles(map()) :: [Role.t()]
  def list_all_roles(user) do
    if Acl.can?(user, "roles.read") do
      Repo.all(Role)
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Retrieves a single role by ID.
  """
  @spec get_role(map(), String.t()) :: {:ok, Role.t()} | {:error, :not_found}
  def get_role(user, id) do
    if Acl.can?(user, "roles.read") do
      case Repo.get(Role, id) do
        nil -> {:error, :not_found}
        role -> {:ok, role}
      end
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Retrieves a role by its unique name.

  Used in release scripts, does not need ACL guards
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
  @spec create_role(map(), map()) :: {:ok, Role.t()} | {:error, Ecto.Changeset.t()}
  def create_role(user, attrs) do
    if Acl.can?(user, "roles.create") do
      system_create_role(attrs)
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Creates a new role.
  """
  @spec system_create_role(map()) :: {:ok, Role.t()} | {:error, Ecto.Changeset.t()}
  def system_create_role(attrs) do
    %Role{}
    |> Role.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates an existing role.
  """
  @spec update_role(map(), Role.t(), map()) :: {:ok, Role.t()} | {:error, Ecto.Changeset.t()}
  def update_role(user, %Role{} = role, attrs) do
    if Acl.can?(user, "roles.update") do
      role
      |> Role.changeset(attrs)
      |> Repo.update()
      |> case do
        {:ok, updated_role} ->
          clear_accounts_cache_for_role(updated_role.id)

          Phoenix.PubSub.broadcast(
            Athena.PubSub,
            "role_updates:#{updated_role.id}",
            :role_updated
          )

          {:ok, updated_role}

        error ->
          error
      end
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Deletes a role and schedules an outbox event in a single transaction.

  Returns `{:error, :role_in_use}` if the role is still assigned to accounts.
  """
  @spec delete_role(map(), Role.t()) ::
          {:ok, map()} | {:error, :role_in_use} | {:error, Ecto.Changeset.t()}
  def delete_role(user, %Role{} = role) do
    if Acl.can?(user, "roles.delete") do
      Ecto.Multi.new()
      |> Ecto.Multi.delete(:role, role_delete_changeset(role))
      |> Repo.transaction()
      |> finalize_delete()
    else
      {:error, :unauthorized}
    end
  end

  @doc false
  defp finalize_delete({:ok, result}), do: {:ok, result}

  defp finalize_delete({:error, :role, %Ecto.Changeset{} = changeset, _changes}) do
    if has_foreign_key_error?(changeset) do
      {:error, :role_in_use}
    else
      {:error, changeset}
    end
  end

  @doc false
  defp role_delete_changeset(role) do
    role
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.foreign_key_constraint(:accounts, name: :accounts__role_id__fk)
  end

  @doc false
  defp has_foreign_key_error?(changeset) do
    Enum.any?(changeset.errors, fn {field, {_, meta}} ->
      field == :accounts and meta[:constraint] == :foreign
    end)
  end

  @doc false
  defp clear_accounts_cache_for_role(role_id) do
    Account
    |> where([a], a.role_id == ^role_id)
    |> select([a], a.id)
    |> Repo.all()
    |> Enum.each(&Cachex.del(:account_cache, &1))
  end
end
