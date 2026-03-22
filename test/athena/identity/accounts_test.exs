defmodule Athena.Identity.AccountsTest do
  use Athena.DataCase, async: true

  alias Athena.Identity.Accounts
  alias Athena.Identity.Account
  import Athena.Factory

  describe "list_accounts/1" do
    test "should return list of accounts with flop pagination" do
      insert_list(3, :account)

      {:ok, {accounts, meta}} = Accounts.list_accounts(%{page: 1, page_size: 2})

      assert length(accounts) == 2
      assert meta.total_count == 3
      assert meta.current_page == 1
    end

    test "should not return soft deleted accounts " do
      active_account = insert(:account)

      insert(:account, deleted_at: DateTime.utc_now(:second))

      {:ok, {accounts, _meta}} = Accounts.list_accounts(%{})

      assert length(accounts) == 1
      assert hd(accounts).id == active_account.id
    end

    test "should preload associations if requested" do
      account = insert(:account)
      insert(:profile, owner: account)

      {:ok, {accounts, _meta}} = Accounts.list_accounts(%{}, preload: [:profile, :role])

      fetched_account = hd(accounts)
      assert fetched_account.profile.id != nil
      assert fetched_account.role.id != nil
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
    test "should return account on success auth" do
      account = insert(:account, login: "admin")

      assert {:ok, auth_account} = Accounts.authenticate("admin", "Password123!")
      assert auth_account.id == account.id
    end

    test "should return error on invalid password" do
      insert(:account, login: "admin")

      assert {:error, :invalid_credentials} = Accounts.authenticate("admin", "WrongPass")
    end

    test "should return error when account doesn't exists" do
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

  describe "register_admin_user/2" do
    test "should create account and profile atomically" do
      role = insert(:role)

      account_attrs = %{
        "login" => "new_admin",
        "password" => "StrongPass1!",
        "role_id" => role.id
      }

      profile_attrs = %{"first_name" => "John", "last_name" => "Doe"}

      assert {:ok, account} = Accounts.register_admin_user(account_attrs, profile_attrs)

      assert account.login == "new_admin"
      assert account.profile.first_name == "John"
      assert account.profile.owner_id == account.id
    end

    test "should rollback if profile validation fails" do
      role = insert(:role)

      account_attrs = %{
        "login" => "new_admin",
        "password" => "StrongPass1!",
        "role_id" => role.id
      }

      profile_attrs = %{"first_name" => ""}

      assert {:error, :profile, changeset} =
               Accounts.register_admin_user(account_attrs, profile_attrs)

      assert "can't be blank" in errors_on(changeset).first_name

      assert Athena.Repo.aggregate(Account, :count, :id) == 0
    end
  end

  describe "update_admin_user/3" do
    test "should update both account and profile" do
      account = insert(:account, login: "old_login")
      insert(:profile, owner: account, first_name: "OldName")

      account_attrs = %{"login" => "new_login"}
      profile_attrs = %{"first_name" => "NewName"}

      assert {:ok, updated_account} =
               Accounts.update_admin_user(account, account_attrs, profile_attrs)

      assert updated_account.login == "new_login"
      assert updated_account.profile.first_name == "NewName"
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

  describe "search_accounts_by_login/2" do
    test "should return accounts matching the login query (case-insensitive)" do
      acc1 = insert(:account, login: "john_doe")
      acc2 = insert(:account, login: "john_smith")
      _acc3 = insert(:account, login: "alice_jones")

      results = Accounts.search_accounts_by_login("John")

      assert length(results) == 2
      ids = Enum.map(results, & &1.id)
      assert acc1.id in ids
      assert acc2.id in ids
    end

    test "should respect the provided limit" do
      insert(:account, login: "test_user_1")
      insert(:account, login: "test_user_2")
      insert(:account, login: "test_user_3")
      insert(:account, login: "test_user_4")
      insert(:account, login: "test_user_5")

      results = Accounts.search_accounts_by_login("test", 3)

      assert length(results) == 3
    end

    test "should return an empty list if no accounts match" do
      insert(:account, login: "test_user")

      results = Accounts.search_accounts_by_login("unknown")

      assert results == []
    end
  end
end
