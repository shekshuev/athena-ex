defmodule AthenaWeb.AdminLive.UserFormComponentTest do
  use AthenaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  import Athena.Factory
  alias Athena.Identity

  setup %{conn: conn} do
    role = insert(:role, permissions: ["admin"])
    admin = insert(:account, role: role)
    conn = init_test_session(conn, %{"account_id" => admin.id})
    %{conn: conn}
  end

  describe "User Form Component" do
    test "validates required fields on change", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/admin/users/new")

      html =
        lv
        |> form("#account-form", %{
          "user_form" => %{"login" => "", "first_name" => ""}
        })
        |> render_change()

      assert html =~ "can&#39;t be blank"
    end

    test "creates a new user with account, profile and password change flag", %{conn: conn} do
      role = insert(:role)

      {:ok, lv, _html} = live(conn, ~p"/admin/users/new")

      lv
      |> form("#account-form", %{
        "user_form" => %{
          "login" => "new_manager",
          "password" => "StrongPass123!",
          "password_confirmation" => "StrongPass123!",
          "must_change_password" => "true",
          "role_id" => role.id,
          "status" => "active",
          "first_name" => "Ivan",
          "last_name" => "Ivanov"
        }
      })
      |> render_submit()

      assert_patch(lv, ~p"/admin/users")

      assert {:ok, account} = Identity.get_account_by_login("new_manager")
      account = Athena.Repo.preload(account, :profile)

      assert account.status == :active
      assert account.role_id == role.id
      assert account.profile.first_name == "Ivan"
      assert account.profile.last_name == "Ivanov"

      assert account.must_change_password == true

      assert render(lv) =~ "User created successfully"
    end

    test "updates an existing user and toggles password change flag", %{conn: conn} do
      role = insert(:role)
      account = insert(:account, login: "old_login", must_change_password: true)
      insert(:profile, owner: account, first_name: "OldName", last_name: "OldLastName")

      {:ok, lv, _html} = live(conn, ~p"/admin/users/#{account.id}/edit")

      lv
      |> form("#account-form", %{
        "user_form" => %{
          "login" => "new_login",
          "role_id" => role.id,
          "first_name" => "NewName",
          "last_name" => "NewLastName",
          "status" => "blocked",
          "must_change_password" => "false"
        }
      })
      |> render_submit()

      assert_patch(lv, ~p"/admin/users")

      {:ok, updated_account} = Identity.get_account(account.id)
      updated_account = Athena.Repo.preload(updated_account, :profile)

      assert updated_account.login == "new_login"
      assert updated_account.status == :blocked
      assert updated_account.profile.first_name == "NewName"
      assert updated_account.profile.last_name == "NewLastName"

      assert updated_account.must_change_password == false
    end
  end
end
