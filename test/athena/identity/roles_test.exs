defmodule Athena.Identity.RolesTest do
  use Athena.DataCase, async: true

  alias Athena.Identity.Roles
  alias Athena.Identity.Role
  import Athena.Factory

  describe "list_roles/1" do
    test "should return list of roles with flop pagination" do
      insert_list(3, :role)

      {:ok, {roles, meta}} = Roles.list_roles(%{page: 1, page_size: 2})

      assert length(roles) == 2
      assert meta.total_count == 3
      assert meta.current_page == 1
    end
  end

  describe "get_role/1 and get_role_by_name/1" do
    test "should return role by id if role exists" do
      role = insert(:role)
      assert {:ok, fetched_role} = Roles.get_role(role.id)
      assert fetched_role.id == role.id
    end

    test "should return role by name if role exists" do
      role = insert(:role, name: "admin")
      assert {:ok, fetched_role} = Roles.get_role_by_name("admin")
      assert fetched_role.id == role.id
    end

    test "should return error if role doesn't exists" do
      fake_id = Ecto.UUID.generate()
      assert {:error, :not_found} = Roles.get_role(fake_id)
      assert {:error, :not_found} = Roles.get_role_by_name("non_existent")
    end
  end

  describe "create_role/1" do
    test "should create role with valid data" do
      attrs = %{name: "Teacher", permissions: ["courses.create"]}

      assert {:ok, %Role{} = role} = Roles.create_role(attrs)
      assert role.name == "Teacher"
      assert role.permissions == ["courses.create"]
      assert role.policies == %{}
    end

    test "should return error when role exists with same login value" do
      insert(:role, name: "Admin")
      attrs = %{name: "Admin"}

      assert {:error, changeset} = Roles.create_role(attrs)
      assert "has already been taken" in errors_on(changeset).name
    end
  end

  describe "update_role/2" do
    test "should update permissions and policies" do
      role = insert(:role, name: "Manager")

      attrs = %{
        permissions: ["users.read", "users.write"],
        policies: %{"users.delete" => ["only_own"]}
      }

      assert {:ok, updated_role} = Roles.update_role(role, attrs)
      assert updated_role.permissions == ["users.read", "users.write"]
      assert updated_role.policies == %{"users.delete" => ["only_own"]}
    end
  end

  describe "delete_role/1" do
    test "should delete role if it doesn't added to someone" do
      role = insert(:role)

      assert {:ok, %{role: _deleted_role}} = Roles.delete_role(role)

      assert {:error, :not_found} = Roles.get_role(role.id)
    end

    test "should not delete role with linked account" do
      account = insert(:account)

      {:ok, role_in_use} = Roles.get_role(account.role_id)

      assert {:error, :role_in_use} = Roles.delete_role(role_in_use)

      assert {:ok, _} = Roles.get_role(role_in_use.id)
    end
  end
end
