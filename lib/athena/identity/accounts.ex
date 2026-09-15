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
  alias Athena.{Repo, Identity, Media, Workers}
  alias Athena.Identity.{Account, Acl, Profile}
  alias Athena.Learning.CohortMembership

  @doc """
  Retrieves a paginated list of accounts with optional preloads.

  ## Parameters
    * `params` - A map containing Flop parameters.
    * `opts` - Keyword list of options (e.g., `[preload: [:profile, :role]]`).
  """
  @spec list_accounts(map(), map(), keyword()) ::
          {:ok, {[Account.t()], Flop.Meta.t()}} | {:error, Flop.Meta.t()}
  def list_accounts(user, params \\ %{}, opts \\ []) do
    base_query =
      Account
      |> where([a], is_nil(a.deleted_at))
      |> Acl.scope_query(user, "users.read")

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
  @spec register_admin_user(map(), map(), map()) ::
          {:ok, Account.t()} | {:error, :account | :profile, Ecto.Changeset.t()}
  def register_admin_user(current_user, account_attrs, profile_attrs) do
    if Acl.can?(current_user, "users.create") do
      Ecto.Multi.new()
      |> Ecto.Multi.insert(:account, Account.changeset(%Account{}, account_attrs))
      |> Ecto.Multi.insert(:profile, fn %{account: account} ->
        attrs = Map.put(profile_attrs, "owner_id", account.id)
        Profile.changeset(%Profile{}, attrs)
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{account: account, profile: profile}} ->
          {:ok, %{account | profile: profile}}

        {:error, failed_operation, changeset, _changes} ->
          {:error, failed_operation, changeset}
      end
    else
      {:error, :forbidden}
    end
  end

  @doc """
  Updates an existing user (Account + Profile) atomically.
  """
  @spec update_admin_user(map(), Account.t(), map(), map()) ::
          {:ok, Account.t()} | {:error, :account | :profile, Ecto.Changeset.t()}
  def update_admin_user(current_user, %Account{} = account, account_attrs, profile_attrs) do
    if Acl.can?(current_user, "users.update", account) do
      account = Repo.preload(account, :profile)

      Ecto.Multi.new()
      |> Ecto.Multi.update(:account, Account.changeset(account, account_attrs))
      |> Ecto.Multi.run(:profile, fn repo, _changes ->
        upsert_profile(repo, account, profile_attrs)
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
    else
      {:error, :forbidden}
    end
  end

  @doc false
  defp upsert_profile(repo, account, profile_attrs) do
    if account.profile do
      account.profile
      |> Profile.changeset(profile_attrs)
      |> repo.update()
    else
      attrs = Map.put(profile_attrs, "owner_id", account.id)

      %Profile{}
      |> Profile.changeset(attrs)
      |> repo.insert()
    end
  end

  @doc """
  Retrieves a single account by its ID.

  ## Returns
    * `{:ok, %Account{}}` if found.
    * `{:error, :not_found}` if the account does not exist.
  """
  @spec get_account(String.t(), keyword()) :: {:ok, Account.t()} | {:error, :not_found}
  def get_account(id, opts \\ []) do
    preloads = Keyword.get(opts, :preload, [])

    case Cachex.get(:account_cache, id) do
      {:ok, nil} ->
        fetch_from_db_and_cache(id, opts)

      {:ok, %Account{} = account} ->
        ensure_preloaded_and_cached(account, preloads, id, opts)

      _ ->
        {:error, :not_found}
    end
  end

  @doc false
  defp fetch_from_db_and_cache(id, opts) do
    case Repo.get(Account, id) do
      nil ->
        {:error, :not_found}

      account ->
        account = maybe_preload_account(account, opts)
        cache_account(id, account)
        {:ok, account}
    end
  end

  @doc false
  defp ensure_preloaded_and_cached(account, preloads, id, opts) do
    if needs_preload?(account, preloads) do
      account = maybe_preload_account(account, opts)
      cache_account(id, account)
      {:ok, account}
    else
      {:ok, account}
    end
  end

  @doc false
  defp needs_preload?(account, preloads) do
    Enum.any?(preloads, fn assoc ->
      match?(%Ecto.Association.NotLoaded{}, Map.get(account, assoc))
    end)
  end

  @doc false
  defp cache_account(id, account) do
    Cachex.put(:account_cache, id, account, ttl: :timer.minutes(5))
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

  ## Security & Brute-force Protection
    * Accounts with `:blocked` or `:temporary_blocked` statuses are immediately rejected.
    * Failed login attempts are tracked. Reaching 3 consecutive failed attempts
      will lock the account (`:temporary_blocked`) and schedule an Oban job to
      unblock it after 30 minutes.
    * Stale failed attempts (older than 60 minutes) are automatically cleared
      upon the next login attempt.
    * A successful login resets the failed attempts counter.

  ## Returns
    * `{:ok, %Account{}}` if credentials are valid and the account is active.
    * `{:error, :invalid_credentials}` if authentication fails (wrong password or non-existent user).
    * `{:error, :account_blocked}` if the account is explicitly blocked or temporarily locked.
  """
  @spec authenticate(String.t(), String.t()) ::
          {:ok, Account.t()} | {:error, :invalid_credentials} | {:error, :account_blocked}
  def authenticate(login, password) do
    account = Repo.get_by(Account, login: login)

    if account do
      account = maybe_clear_stale_attempts(account)
      valid_pass? = Argon2.verify_pass(password, account.password_hash)

      cond do
        account.status in [:blocked, :temporary_blocked] ->
          {:error, :account_blocked}

        valid_pass? ->
          reset_failed_attempts(account)
          {:ok, account}

        true ->
          handle_failed_attempt(account)
          {:error, :invalid_credentials}
      end
    else
      Argon2.no_user_verify()
      {:error, :invalid_credentials}
    end
  end

  @doc false
  defp maybe_clear_stale_attempts(
         %Account{failed_login_attempts: attempts, last_failed_at: last_failed} = account
       )
       when attempts > 0 and not is_nil(last_failed) do
    if DateTime.diff(DateTime.utc_now(:second), last_failed, :minute) > 60 do
      {:ok, acc} = update_account(account, %{failed_login_attempts: 0, last_failed_at: nil})
      acc
    else
      account
    end
  end

  defp maybe_clear_stale_attempts(account), do: account

  defp reset_failed_attempts(%Account{failed_login_attempts: attempts} = account)
       when attempts > 0 do
    update_account(account, %{failed_login_attempts: 0, last_failed_at: nil})
  end

  defp reset_failed_attempts(_account), do: :ok

  defp handle_failed_attempt(account) do
    new_attempts = account.failed_login_attempts + 1

    if new_attempts >= 3 do
      {:ok, blocked_acc} =
        update_account(account, %{
          status: :temporary_blocked,
          failed_login_attempts: new_attempts,
          last_failed_at: DateTime.utc_now(:second)
        })

      %{account_id: blocked_acc.id}
      |> Workers.UnblockAccount.new(schedule_in: 30 * 60)
      |> Oban.insert()
    else
      update_account(account, %{
        failed_login_attempts: new_attempts,
        last_failed_at: DateTime.utc_now(:second)
      })
    end
  end

  @doc """
  Updates the caller's own profile (name fields, avatar, etc).

  No ACL check — the caller is always allowed to edit their own profile,
  regardless of `users.update` permissions (which gate editing *other*
  accounts via `update_admin_user/4`).
  """
  @spec update_own_profile(Account.t(), map()) ::
          {:ok, Profile.t()} | {:error, Ecto.Changeset.t()}
  def update_own_profile(%Account{} = account, profile_attrs) do
    account = Repo.preload(account, :profile)
    old_avatar_url = account.profile && account.profile.avatar_url

    case upsert_profile(Repo, account, profile_attrs) do
      {:ok, profile} ->
        Cachex.del(:account_cache, account.id)
        cleanup_old_avatar(old_avatar_url, profile.avatar_url)

        Phoenix.PubSub.broadcast(
          Athena.PubSub,
          "account_updates:#{account.id}",
          :account_updated
        )

        {:ok, profile}

      error ->
        error
    end
  end

  # `Profile.avatar_url` is a plain string (not a `Media.File` foreign key,
  # unlike `Character.avatar_file_id`), so the only way to find the
  # replaced file is by parsing its key back out of the old `/media/...`
  # URL. Without this, every avatar change leaked the previous upload
  # (S3 object + `media_files` row) forever — nothing ever cleaned it up,
  # since `Athena.Workers.MediaCleanup` only garbage-collects
  # `:course_material`/`:submission` files, not `:avatar` ones.
  @doc false
  defp cleanup_old_avatar(old_url, new_url) when is_binary(old_url) and old_url != new_url do
    case old_url do
      "/media/" <> key -> Media.delete_file_by_key(key)
      _ -> :ok
    end
  end

  defp cleanup_old_avatar(_old_url, _new_url), do: :ok

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
  Returns a map of `%{account_id => Account}` (with `:profile` preloaded) for
  bulk enrichment across contexts.
  """
  @spec get_accounts_map([String.t()]) :: %{String.t() => Account.t()}
  def get_accounts_map(ids) when is_list(ids) do
    Account
    |> where([a], a.id in ^ids)
    |> preload(:profile)
    |> Repo.all()
    |> Map.new(&{&1.id, &1})
  end

  @doc """
  Searches accounts by login using case-insensitive partial matching (`ilike`).
  Useful for cross-context autocomplete features.
  """
  @spec search_accounts_by_login(map(), String.t(), integer()) :: [Account.t()]
  def search_accounts_by_login(user, query, limit \\ 10) do
    search_term = "%#{query}%"

    Account
    |> where([a], ilike(a.login, ^search_term))
    |> Identity.scope_query(user, "users.read")
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Searches active, non-deleted accounts by login OR profile name
  (first/last/patronymic), for the open messenger's "start a new
  conversation" flow.

  Deliberately does **not** scope via `Identity.scope_query/3`/`"users.read"`
  the way `search_accounts_by_login/3` does above: the messenger is
  intentionally open (any user may start a conversation with any other
  active user), so only account status is enforced here, not the
  `"users.read"` ACL permission. This is a deliberate, documented exception
  to the ACL system.
  """
  @spec search_messageable_accounts(Account.t(), String.t(), integer()) :: [Account.t()]
  def search_messageable_accounts(current_user, query, limit \\ 10) do
    query
    |> open_account_search_query()
    |> where([a], a.id != ^current_user.id)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Searches active, non-deleted accounts by login OR profile name
  (first/last/patronymic), for the open "add student to cohort" flow.
  Accounts already belonging to the given cohort are excluded.

  Deliberately open like `search_messageable_accounts/3` above: looking a
  user up is harmless, only the mutation is permission-gated (see
  `Athena.Learning.add_student_to_cohort/3`, which still requires
  `"cohorts.update"`/`"teams.update"` and is unaffected by this function).
  """
  @spec search_addable_cohort_accounts(String.t(), String.t(), integer()) :: [Account.t()]
  def search_addable_cohort_accounts(cohort_id, query, limit \\ 10) do
    member_ids =
      from(m in CohortMembership, where: m.cohort_id == ^cohort_id, select: m.account_id)

    query
    |> open_account_search_query()
    |> where([a], a.id not in subquery(member_ids))
    |> limit(^limit)
    |> Repo.all()
  end

  @doc false
  defp open_account_search_query(query) do
    term = "%#{query}%"

    from(a in Account,
      left_join: p in Profile,
      on: p.owner_id == a.id,
      where: a.status == :active and is_nil(a.deleted_at),
      where:
        ilike(a.login, ^term) or ilike(p.first_name, ^term) or ilike(p.last_name, ^term) or
          ilike(p.patronymic, ^term),
      order_by: [asc: a.login],
      preload: [profile: p]
    )
  end

  @doc """
  Returns the account's display name: their profile's full name if set,
  otherwise their login. Safe to call whether or not `:profile` is preloaded.
  """
  @spec display_name(Account.t()) :: String.t()
  def display_name(%Account{profile: %Profile{} = profile}), do: Profile.full_name(profile)
  def display_name(%Account{login: login}), do: login

  @doc """
  Updates the account's `last_seen_at` timestamp to now. Used by
  `AthenaWeb.Presence` when a user's presence fully drops (all their tabs
  disconnect).
  """
  @spec touch_last_seen(String.t()) :: :ok
  def touch_last_seen(account_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(a in Account, where: a.id == ^account_id)
    |> Repo.update_all(set: [last_seen_at: now])

    :ok
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

  @doc """
  Retrieves a list of account IDs matching a partial login string.
  Useful for cross-context filtering (like Flop).
  """
  @spec get_account_ids_by_login(String.t()) :: [String.t()]
  def get_account_ids_by_login(query) do
    search_term = "%#{query}%"

    Account
    |> where([a], ilike(a.login, ^search_term))
    |> select([a], a.id)
    |> Repo.all()
  end

  @doc """
  Clears the entire account cache.

  Useful for debugging or forcing a reload of all user data from the database.
  """
  @spec clear_cache() :: {:ok, non_neg_integer()} | {:error, any()}
  def clear_cache() do
    Cachex.clear(:account_cache)
  end
end
