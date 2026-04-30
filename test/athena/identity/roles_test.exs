defmodule Athena.Identity.RolesTest do
  use Athena.DataCase, async: true

  alias Athena.Identity.{Role, Roles, Account}
  import Athena.Factory

  setup do
    admin_role =
      insert(:role,
        permissions: ["roles.read", "roles.create", "roles.update", "roles.delete"]
      )

    admin = insert(:account, role: admin_role)

    student = insert(:account, role: insert(:role, permissions: []))

    %{admin: admin, student: student}
  end

  describe "list_roles/2 and list_all_roles/1" do
    test "should return list of roles with flop pagination", %{admin: admin} do
      insert_list(3, :role)

      {:ok, {roles, meta}} = Roles.list_roles(admin, %{page: 1, page_size: 2})

      assert length(roles) == 2
      assert meta.total_count == 5
      assert meta.current_page == 1
    end

    test "should return all roles without pagination", %{admin: admin} do
      insert_list(2, :role)
      roles = Roles.list_all_roles(admin)
      # 2 из сетапа + 2 новых
      assert length(roles) == 4
    end

    test "should return unauthorized if user lacks roles.read", %{student: student} do
      assert {:error, :unauthorized} = Roles.list_roles(student, %{})
      assert {:error, :unauthorized} = Roles.list_all_roles(student)
    end
  end

  describe "get_role/2 and get_role_by_name/1" do
    test "should return role by id if role exists and user has rights", %{admin: admin} do
      role = insert(:role)
      assert {:ok, fetched_role} = Roles.get_role(admin, role.id)
      assert fetched_role.id == role.id
    end

    test "should return role by name if role exists (no ACL needed)" do
      role = insert(:role, name: "system_admin")
      assert {:ok, fetched_role} = Roles.get_role_by_name("system_admin")
      assert fetched_role.id == role.id
    end

    test "should return error if role doesn't exist", %{admin: admin} do
      fake_id = Ecto.UUID.generate()
      assert {:error, :not_found} = Roles.get_role(admin, fake_id)
      assert {:error, :not_found} = Roles.get_role_by_name("non_existent")
    end

    test "should return unauthorized if user lacks roles.read", %{student: student} do
      role = insert(:role)
      assert {:error, :unauthorized} = Roles.get_role(student, role.id)
    end
  end

  describe "create_role/2" do
    test "should create role with valid data", %{admin: admin} do
      attrs = %{name: "Teacher", permissions: ["courses.create"]}

      assert {:ok, %Role{} = role} = Roles.create_role(admin, attrs)
      assert role.name == "Teacher"
      assert role.permissions == ["courses.create"]
      assert role.policies == %{}
    end

    test "should return error when role exists with same name", %{admin: admin} do
      insert(:role, name: "SuperAdmin")
      attrs = %{name: "SuperAdmin"}

      assert {:error, changeset} = Roles.create_role(admin, attrs)
      assert "has already been taken" in errors_on(changeset).name
    end

    test "should return unauthorized if user lacks roles.create", %{student: student} do
      attrs = %{name: "HackerRole", permissions: ["admin"]}
      assert {:error, :unauthorized} = Roles.create_role(student, attrs)
    end
  end

  describe "update_role/3" do
    test "should update permissions and policies", %{admin: admin} do
      role = insert(:role, name: "Manager")

      attrs = %{
        permissions: ["users.read", "users.update"],
        policies: %{"users.delete" => ["own_only"]}
      }

      assert {:ok, updated_role} = Roles.update_role(admin, role, attrs)
      assert updated_role.permissions == ["users.read", "users.update"]
      assert updated_role.policies == %{"users.delete" => ["own_only"]}
    end

    test "should clear associated accounts from cache on role update", %{admin: admin} do
      role = insert(:role)
      account1 = insert(:account, role: role)
      account2 = insert(:account, role: role)

      other_role = insert(:role)
      other_account = insert(:account, role: other_role)

      Cachex.put(:account_cache, account1.id, account1)
      Cachex.put(:account_cache, account2.id, account2)
      Cachex.put(:account_cache, other_account.id, other_account)

      assert {:ok, %Account{}} = Cachex.get(:account_cache, account1.id)
      assert {:ok, %Account{}} = Cachex.get(:account_cache, account2.id)
      assert {:ok, %Account{}} = Cachex.get(:account_cache, other_account.id)

      assert {:ok, _updated_role} = Roles.update_role(admin, role, %{name: "Updated Role"})

      assert {:ok, nil} = Cachex.get(:account_cache, account1.id)
      assert {:ok, nil} = Cachex.get(:account_cache, account2.id)

      assert {:ok, cached_other} = Cachex.get(:account_cache, other_account.id)
      assert cached_other.id == other_account.id
    end

    test "should return unauthorized if user lacks roles.update", %{student: student} do
      role = insert(:role)
      attrs = %{name: "Pwned Role"}
      assert {:error, :unauthorized} = Roles.update_role(student, role, attrs)
    end
  end

  describe "delete_role/2" do
    test "should delete role if it isn't linked to anyone", %{admin: admin} do
      role = insert(:role)

      assert {:ok, %{role: _deleted_role}} = Roles.delete_role(admin, role)
      assert {:error, :not_found} = Roles.get_role(admin, role.id)
    end

    test "should not delete role with linked account", %{admin: admin} do
      account = insert(:account)

      {:ok, role_in_use} = Roles.get_role(admin, account.role_id)

      assert {:error, :role_in_use} = Roles.delete_role(admin, role_in_use)
      assert {:ok, _} = Roles.get_role(admin, role_in_use.id)
    end

    test "should return unauthorized if user lacks roles.delete", %{student: student} do
      role = insert(:role)
      assert {:error, :unauthorized} = Roles.delete_role(student, role)
    end
  end
end
