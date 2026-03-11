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
  end

  describe "get_account/1" do
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
end
