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
  Retrieves a paginated list of accounts with optional preloads.

  ## Parameters
    * `params` - A map containing Flop parameters.
    * `opts` - Keyword list of options (e.g., `[preload: [:profile, :role]]`).
  """
  @spec list_accounts(map(), keyword()) ::
          {:ok, {[Account.t()], Flop.Meta.t()}} | {:error, Flop.Meta.t()}
  def list_accounts(params \\ %{}, opts \\ []) do
    base_query = where(Account, [a], is_nil(a.deleted_at))

    query =
      if preloads = Keyword.get(opts, :preload) do
        preload(base_query, ^preloads)
      else
        base_query
      end

    Flop.validate_and_run(query, params, for: Account)
  end

  @doc """
  Registers a new user (Account + Profile) atomically in a single transaction.
  """
  @spec register_admin_user(map(), map()) ::
          {:ok, Account.t()} | {:error, :account | :profile, Ecto.Changeset.t()}
  def register_admin_user(account_attrs, profile_attrs) do
    Ecto.Multi.new()
    |> Ecto.Multi.insert(:account, Account.changeset(%Account{}, account_attrs))
    |> Ecto.Multi.insert(:profile, fn %{account: account} ->
      attrs = Map.put(profile_attrs, "owner_id", account.id)
      Athena.Identity.Profile.changeset(%Athena.Identity.Profile{}, attrs)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{account: account, profile: profile}} ->
        {:ok, %{account | profile: profile}}

      {:error, failed_operation, changeset, _changes} ->
        {:error, failed_operation, changeset}
    end
  end

  @doc """
  Updates an existing user (Account + Profile) atomically.
  """
  @spec update_admin_user(Account.t(), map(), map()) ::
          {:ok, Account.t()} | {:error, :account | :profile, Ecto.Changeset.t()}
  def update_admin_user(%Account{} = account, account_attrs, profile_attrs) do
    account = Repo.preload(account, :profile)

    Ecto.Multi.new()
    |> Ecto.Multi.update(:account, Account.changeset(account, account_attrs))
    |> Ecto.Multi.run(:profile, fn repo, _changes ->
      if account.profile do
        account.profile
        |> Athena.Identity.Profile.changeset(profile_attrs)
        |> repo.update()
      else
        attrs = Map.put(profile_attrs, "owner_id", account.id)

        %Athena.Identity.Profile{}
        |> Athena.Identity.Profile.changeset(attrs)
        |> repo.insert()
      end
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{account: updated_account, profile: updated_profile}} ->
        Cachex.del(:account_cache, updated_account.id)

        Phoenix.PubSub.broadcast(
          Athena.PubSub,
          "account_updates:#{updated_account.id}",
          :account_updated
        )

        {:ok, %{updated_account | profile: updated_profile}}

      {:error, failed_operation, changeset, _changes} ->
        {:error, failed_operation, changeset}
    end
  end

  @doc """
  Retrieves a single account by its ID.

  ## Returns
    * `{:ok, %Account{}}` if found.
    * `{:error, :not_found}` if the account does not exist.
  """
  @spec get_account(String.t()) :: {:ok, Account.t()} | {:error, :not_found}
  def get_account(id, opts \\ []) do
    case Cachex.get(:account_cache, id) do
      {:ok, nil} ->
        case Repo.get(Account, id) do
          nil ->
            {:error, :not_found}

          account ->
            account = maybe_preload_account(account, opts)
            Cachex.put(:account_cache, id, account, ttl: :timer.minutes(5))

            {:ok, account}
        end

      {:ok, %Account{} = account} ->
        {:ok, account}
    end
  end

  @doc false
  defp maybe_preload_account(account, opts) do
    case Keyword.get(opts, :preload) do
      nil -> account
      preloads -> Repo.preload(account, preloads)
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

  @doc """
  Returns a map of `%{account_id => Account}` for bulk enrichment across contexts.
  """
  @spec get_accounts_map([String.t()]) :: %{String.t() => Account.t()}
  def get_accounts_map(ids) when is_list(ids) do
    Account
    |> where([a], a.id in ^ids)
    |> Repo.all()
    |> Map.new(&{&1.id, &1})
  end

  @doc """
  Searches accounts by login using case-insensitive partial matching (`ilike`).
  Useful for cross-context autocomplete features.
  """
  @spec search_accounts_by_login(String.t(), integer()) :: [Account.t()]
  def search_accounts_by_login(query, limit \\ 10) do
    search_term = "%#{query}%"

    Account
    |> where([a], ilike(a.login, ^search_term))
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Forces a password change and clears the `must_change_password` flag.
  """
  @spec force_change_password(Account.t(), map()) ::
          {:ok, Account.t()} | {:error, Ecto.Changeset.t()}
  def force_change_password(%Account{} = account, attrs) do
    account
    |> Account.force_password_changeset(attrs)
    |> Repo.update()
    |> case do
      {:ok, updated_account} ->
        Cachex.del(:account_cache, updated_account.id)
        {:ok, updated_account}

      error ->
        error
    end
  end
end
