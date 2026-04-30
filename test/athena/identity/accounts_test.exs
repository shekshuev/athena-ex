defmodule Athena.Identity.AccountsTest do
  use Athena.DataCase, async: true

  alias Athena.Identity.Accounts
  alias Athena.Identity.Account
  import Athena.Factory

  setup do
    admin_role =
      insert(:role, permissions: ["users.read", "users.update", "users.create", "users.delete"])

    admin = insert(:account, role: admin_role)

    student = insert(:account, role: insert(:role, permissions: []))

    %{admin: admin, student: student}
  end

  describe "list_accounts/3" do
    test "should return list of accounts with flop pagination", %{admin: admin} do
      insert_list(3, :account)

      {:ok, {accounts, meta}} = Accounts.list_accounts(admin, %{page: 1, page_size: 2})

      assert length(accounts) == 2
      assert meta.total_count == 5
      assert meta.current_page == 1
    end

    test "should not return soft deleted accounts", %{admin: admin} do
      active_account = insert(:account)
      deleted_account = insert(:account, deleted_at: DateTime.utc_now(:second))

      {:ok, {accounts, _meta}} = Accounts.list_accounts(admin, %{})

      assert Enum.any?(accounts, &(&1.id == active_account.id))
      refute Enum.any?(accounts, &(&1.id == deleted_account.id))
    end

    test "should preload associations if requested", %{admin: admin} do
      account = insert(:account)
      insert(:profile, owner: account)

      {:ok, {accounts, _meta}} = Accounts.list_accounts(admin, %{}, preload: [:profile, :role])

      fetched_account = Enum.find(accounts, &(&1.id == account.id))
      assert fetched_account.profile.id != nil
      assert fetched_account.role.id != nil
    end

    test "student without users.read gets an empty list (due to scope_query)", %{student: student} do
      insert_list(3, :account)
      {:ok, {accounts, _meta}} = Accounts.list_accounts(student, %{})
      assert accounts == []
    end
  end

  describe "get_account/2" do
    test "should return account if exists" do
      account = insert(:account)

      {:ok, fetched_account} = Accounts.get_account(account.id)

      assert fetched_account.id == account.id
      assert fetched_account.login == account.login
    end

    test "should return error if account doesn't exists" do
      fake_id = Ecto.UUID.generate()
      assert {:error, :not_found} = Accounts.get_account(fake_id)
    end

    test "should preload associations if requested" do
      account = insert(:account)
      insert(:profile, owner: account)

      assert {:ok, fetched_account} = Accounts.get_account(account.id, preload: [:profile, :role])

      assert fetched_account.profile.id != nil
      assert fetched_account.role.id != nil
      assert fetched_account.profile.owner_id == account.id
    end
  end

  describe "create_account/1" do
    test "should create account with valid data" do
      role = insert(:role)
      attrs = %{login: "valid_login", password: "Password123!", role_id: role.id}

      assert {:ok, %Account{} = account} = Accounts.create_account(attrs)
      assert account.login == "valid_login"
      assert account.password_hash != nil
    end

    test "should return error changeset with invalid data" do
      attrs = %{login: "xy", password: "123"}

      assert {:error, changeset} = Accounts.create_account(attrs)

      assert "should be at least 3 character(s)" in errors_on(changeset).login
      assert "can't be blank" in errors_on(changeset).role_id

      assert Enum.any?(
               errors_on(changeset).password,
               &String.starts_with?(&1, "must be at least 8")
             )
    end
  end

  describe "authenticate/2" do
    test "should return account and reset attempts on success auth" do
      account =
        insert(:account,
          login: "admin_user",
          failed_login_attempts: 2,
          last_failed_at: DateTime.utc_now(:second)
        )

      assert {:ok, auth_account} = Accounts.authenticate("admin_user", "Password123!")
      assert auth_account.id == account.id

      updated_account = Athena.Repo.get!(Account, account.id)
      assert updated_account.failed_login_attempts == 0
      assert updated_account.last_failed_at == nil
    end

    test "should return error on invalid password and increment attempts" do
      account = insert(:account, login: "target_admin", failed_login_attempts: 0)

      assert {:error, :invalid_credentials} = Accounts.authenticate("target_admin", "WrongPass")

      updated_account = Athena.Repo.get!(Account, account.id)
      assert updated_account.failed_login_attempts == 1
      assert updated_account.last_failed_at != nil
    end

    test "should block account temporarily on 3rd failed attempt" do
      account = insert(:account, login: "target", failed_login_attempts: 2)

      assert {:error, :invalid_credentials} = Accounts.authenticate("target", "WrongPass")

      updated_account = Athena.Repo.get!(Account, account.id)
      assert updated_account.failed_login_attempts == 3
      assert updated_account.status == :temporary_blocked
      assert_enqueued(worker: Athena.Workers.UnblockAccount, args: %{account_id: account.id})
    end

    test "should clear stale failed attempts (> 60 mins) before processing" do
      stale_time = DateTime.add(DateTime.utc_now(:second), -65, :minute)

      account =
        insert(:account,
          login: "stale_user",
          failed_login_attempts: 2,
          last_failed_at: stale_time
        )

      assert {:error, :invalid_credentials} = Accounts.authenticate("stale_user", "WrongPass")

      updated_account = Athena.Repo.get!(Account, account.id)
      assert updated_account.failed_login_attempts == 1
      assert updated_account.status == :active
    end

    test "should return error when account is permanently blocked" do
      insert(:account, login: "bad_guy", status: :blocked)
      assert {:error, :account_blocked} = Accounts.authenticate("bad_guy", "Password123!")
    end

    test "should return error when account is temporarily blocked (even with correct password)" do
      insert(:account, login: "temp_guy", status: :temporary_blocked)
      assert {:error, :account_blocked} = Accounts.authenticate("temp_guy", "Password123!")
    end

    test "should return error when account doesn't exist" do
      assert {:error, :invalid_credentials} = Accounts.authenticate("ghost", "Password123!")
    end
  end

  describe "change_password/3" do
    test "should change password with correct old one" do
      account = insert(:account)

      assert {:ok, updated_account} =
               Accounts.change_password(account, "Password123!", "NewStrongPass1!")

      assert updated_account.password_hash != account.password_hash
    end

    test "should return error with incorrect old password" do
      account = insert(:account)

      assert {:error, :invalid_old_password} =
               Accounts.change_password(account, "WrongOldPass", "NewStrongPass1!")
    end
  end

  describe "register_admin_user/3" do
    test "should create account and profile atomically", %{admin: admin} do
      role = insert(:role)

      account_attrs = %{
        "login" => "new_admin",
        "password" => "StrongPass1!",
        "role_id" => role.id
      }

      profile_attrs = %{"first_name" => "John", "last_name" => "Doe"}

      assert {:ok, account} = Accounts.register_admin_user(admin, account_attrs, profile_attrs)

      assert account.login == "new_admin"
      assert account.profile.first_name == "John"
    end

    test "should rollback if profile validation fails", %{admin: admin} do
      role = insert(:role)

      account_attrs = %{
        "login" => "new_admin_2",
        "password" => "StrongPass1!",
        "role_id" => role.id
      }

      profile_attrs = %{"first_name" => ""}

      assert {:error, :profile, changeset} =
               Accounts.register_admin_user(admin, account_attrs, profile_attrs)

      assert "can't be blank" in errors_on(changeset).first_name
    end

    test "should return unauthorized if user lacks users.create", %{student: student} do
      assert {:error, :unauthorized} = Accounts.register_admin_user(student, %{}, %{})
    end
  end

  describe "update_admin_user/4" do
    test "should update both account and profile", %{admin: admin} do
      account = insert(:account, login: "old_login")
      insert(:profile, owner: account, first_name: "OldName")

      account_attrs = %{"login" => "new_login"}
      profile_attrs = %{"first_name" => "NewName"}

      assert {:ok, updated_account} =
               Accounts.update_admin_user(admin, account, account_attrs, profile_attrs)

      assert updated_account.login == "new_login"
      assert updated_account.profile.first_name == "NewName"
    end

    test "student returns unauthorized when trying to update another user", %{student: student} do
      account = insert(:account)
      assert {:error, :unauthorized} = Accounts.update_admin_user(student, account, %{}, %{})
    end
  end

  describe "get_accounts_map/1" do
    test "should return a map of accounts keyed by their IDs" do
      account1 = insert(:account)
      account2 = insert(:account)
      _unrelated_account = insert(:account)

      result = Accounts.get_accounts_map([account1.id, account2.id])

      assert is_map(result)
      assert map_size(result) == 2
      assert Map.has_key?(result, account1.id)
      assert Map.has_key?(result, account2.id)
      assert result[account1.id].login == account1.login
    end

    test "should ignore non-existent IDs" do
      account = insert(:account)
      fake_id = Ecto.UUID.generate()

      result = Accounts.get_accounts_map([account.id, fake_id])

      assert map_size(result) == 1
      assert Map.has_key?(result, account.id)
      refute Map.has_key?(result, fake_id)
    end

    test "should return an empty map for an empty list" do
      assert Accounts.get_accounts_map([]) == %{}
    end
  end

  describe "search_accounts_by_login/3" do
    test "should return accounts matching the login query (case-insensitive)", %{admin: admin} do
      acc1 = insert(:account, login: "john_doe")
      acc2 = insert(:account, login: "john_smith")
      _acc3 = insert(:account, login: "alice_jones")

      results = Accounts.search_accounts_by_login(admin, "John")

      assert length(results) == 2
      ids = Enum.map(results, & &1.id)
      assert acc1.id in ids
      assert acc2.id in ids
    end

    test "should respect the provided limit", %{admin: admin} do
      insert(:account, login: "test_user_1")
      insert(:account, login: "test_user_2")
      insert(:account, login: "test_user_3")
      insert(:account, login: "test_user_4")
      insert(:account, login: "test_user_5")

      results = Accounts.search_accounts_by_login(admin, "test_user", 3)

      assert length(results) == 3
    end

    test "should return an empty list if no accounts match", %{admin: admin} do
      insert(:account, login: "test_user")
      results = Accounts.search_accounts_by_login(admin, "unknown")
      assert results == []
    end

    test "student without users.read gets an empty list (due to scope_query)", %{student: student} do
      insert(:account, login: "john_doe")
      results = Accounts.search_accounts_by_login(student, "john")
      assert results == []
    end
  end

  describe "force_change_password/3" do
    test "successfully changes password, resets must_change_password flag and clears cache" do
      account = insert(:account, must_change_password: true)
      old_hash = account.password_hash

      Cachex.put(:account_cache, account.id, account)

      attrs = %{"password" => "NewStrongPass1!"}

      assert {:ok, updated_account} = Accounts.force_change_password(account, attrs)
      assert updated_account.must_change_password == false
      assert updated_account.password_hash != old_hash
      assert {:ok, nil} = Cachex.get(:account_cache, account.id)
    end

    test "returns error changeset when password does not meet requirements" do
      account = insert(:account, must_change_password: true)
      old_hash = account.password_hash

      attrs = %{"password" => "123"}

      assert {:error, changeset} = Accounts.force_change_password(account, attrs)

      assert Enum.any?(
               errors_on(changeset).password,
               &String.starts_with?(&1, "must be at least 8")
             )

      db_account = Athena.Repo.get(Account, account.id)
      assert db_account.must_change_password == true
      assert db_account.password_hash == old_hash
    end
  end

  describe "get_account_ids_by_login/1" do
    test "returns a list of account ids matching the login query (case-insensitive)" do
      acc1 = insert(:account, login: "super_student")
      acc2 = insert(:account, login: "Student_007")
      _acc3 = insert(:account, login: "teacher")

      ids = Accounts.get_account_ids_by_login("student")

      assert length(ids) == 2
      assert acc1.id in ids
      assert acc2.id in ids
    end

    test "returns an empty list if no accounts match" do
      insert(:account, login: "test_user")

      ids = Accounts.get_account_ids_by_login("unknown")

      assert ids == []
    end
  end
end
