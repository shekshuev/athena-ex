defmodule Athena.Identity.Accounts do
  @moduledoc """
  Internal business logic for the Account entity.

  This module handles database interactions, authentication, and secure 
  password management. It is designed to be used exclusively through 
  the public API of the `Athena.Identity` context.

  **Note:** Since this application uses Phoenix LiveView and standard 
  server-side sessions, JWT generation and validation are not required.
  """

  import Ecto.Query
  alias Athena.Repo
  alias Athena.Identity.Account

  @doc """
  Retrieves a paginated list of accounts.

  Uses `Flop` to handle pagination, sorting, and filtering securely based on the 
  schema definitions. It automatically excludes soft-deleted accounts.

  ## Parameters
    * `params` - A map containing Flop parameters (e.g., `%{page: 1, page_size: 20}`).

  ## Returns
    * `{:ok, {accounts, flop_meta}}` - A tuple with the list of accounts and pagination metadata.
    * `{:error, flop_meta}` - If the provided Flop parameters are invalid.
  """
  @spec list_accounts(map()) :: {:ok, {[Account.t()], Flop.Meta.t()}} | {:error, Flop.Meta.t()}
  def list_accounts(params \\ %{}) do
    base_query = where(Account, [a], is_nil(a.deleted_at))

    Flop.validate_and_run(base_query, params, for: Account)
  end

  @doc """
  Retrieves a single account by its ID.

  ## Returns
    * `{:ok, %Account{}}` if found.
    * `{:error, :not_found}` if the account does not exist.
  """
  @spec get_account(String.t()) :: {:ok, Account.t()} | {:error, :not_found}
  def get_account(id) do
    case Cachex.get(:account_cache, id) do
      {:ok, nil} ->
        case Repo.get(Account, id) do
          nil ->
            {:error, :not_found}

          account ->
            Cachex.put(:account_cache, id, account, ttl: :timer.minutes(5))
            {:ok, account}
        end

      {:ok, %Account{} = account} ->
        {:ok, account}
    end
  end

  @doc """
  Retrieves a single account by its login.
  """
  @spec get_account_by_login(String.t()) :: {:ok, Account.t()} | {:error, :not_found}
  def get_account_by_login(login) do
    case Repo.get_by(Account, login: login) do
      nil -> {:error, :not_found}
      account -> {:ok, account}
    end
  end

  @doc """
  Creates a new account and hashes the password securely.

  Returns `{:error, %Ecto.Changeset{}}` if validation fails (e.g., login already taken).
  """
  @spec create_account(map()) :: {:ok, Account.t()} | {:error, Ecto.Changeset.t()}
  def create_account(attrs) do
    %Account{}
    |> Account.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates an existing account.

  If a new password is provided in `attrs`, it will be hashed and updated.
  """
  @spec update_account(Account.t(), map()) :: {:ok, Account.t()} | {:error, Ecto.Changeset.t()}
  def update_account(%Account{} = account, attrs) do
    account
    |> Account.changeset(attrs)
    |> Repo.update()
    |> case do
      {:ok, updated_account} ->
        Cachex.del(:account_cache, updated_account.id)
        {:ok, updated_account}

      error ->
        error
    end
  end

  @doc """
  Soft-deletes an account by setting the `deleted_at` timestamp.
  """
  @spec soft_delete_account(Account.t()) :: {:ok, Account.t()} | {:error, Ecto.Changeset.t()}
  def soft_delete_account(%Account{} = account) do
    account
    |> Ecto.Changeset.change(%{deleted_at: DateTime.utc_now(:second)})
    |> Repo.update()
    |> case do
      {:ok, deleted_account} ->
        Cachex.del(:account_cache, deleted_account.id)
        {:ok, deleted_account}

      error ->
        error
    end
  end

  @doc """
  Authenticates a user by their login and password.

  Uses `Argon2.verify_pass/2` to check the hash. It also safely handles 
  non-existent users via `Argon2.no_user_verify/0` to prevent timing attacks.

  ## Returns
    * `{:ok, %Account{}}` if credentials are valid.
    * `{:error, :invalid_credentials}` if authentication fails.
  """
  @spec authenticate(String.t(), String.t()) ::
          {:ok, Account.t()} | {:error, :invalid_credentials}
  def authenticate(login, password) do
    account = Repo.get_by(Account, login: login)

    cond do
      account && Argon2.verify_pass(password, account.password_hash) ->
        {:ok, account}

      account ->
        {:error, :invalid_credentials}

      true ->
        # Timing attack prevention
        Argon2.no_user_verify()
        {:error, :invalid_credentials}
    end
  end

  @doc """
  Changes the password for a given account, verifying the old password first.
  """
  @spec change_password(Account.t(), String.t(), String.t()) ::
          {:ok, Account.t()}
          | {:error, :invalid_old_password}
          | {:error, Ecto.Changeset.t()}
  def change_password(%Account{} = account, old_password, new_password) do
    if Argon2.verify_pass(old_password, account.password_hash) do
      update_account(account, %{password: new_password})
    else
      {:error, :invalid_old_password}
    end
  end
end
