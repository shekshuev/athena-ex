defmodule AthenaWeb.AdminLive.RoleFormComponentTest do
  use AthenaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  import Athena.Factory
  alias Athena.Identity.Roles

  setup %{conn: conn} do
    role = insert(:role, permissions: ["admin"])
    admin = insert(:account, role: role)
    conn = init_test_session(conn, %{"account_id" => admin.id})
    %{conn: conn}
  end

  describe "Role Form Component" do
    test "validates required fields on change", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/admin/roles/new")

      html =
        lv
        |> form("#role-form", %{
          "role" => %{"name" => ""}
        })
        |> render_change()

      assert html =~ "can&#39;t be blank"
    end

    test "creates a new role with permissions and policies", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/admin/roles/new")

      lv
      |> form("#role-form", %{
        "role" => %{
          "name" => "Super Content Manager",
          "permissions" => ["courses.create", "courses.read"]
        }
      })
      |> render_change()

      assert has_element?(
               lv,
               "input[name=\"role[policies][courses.read][]\"][value=\"own_only\"]"
             )

      lv
      |> form("#role-form", %{
        "role" => %{
          "name" => "Super Content Manager",
          "permissions" => ["courses.create", "courses.read"],
          "policies" => %{
            "courses.read" => ["own_only"]
          }
        }
      })
      |> render_submit()

      assert_patch(lv, ~p"/admin/roles")
      assert {:ok, role} = Roles.get_role_by_name("Super Content Manager")
      assert "courses.create" in role.permissions
      assert "own_only" in role.policies["courses.read"]
    end

    test "updates an existing role", %{conn: conn} do
      role = insert(:role, name: "Old Boring Name", permissions: ["users.read"])

      {:ok, lv, _html} = live(conn, ~p"/admin/roles/#{role.id}/edit")

      lv
      |> form("#role-form", %{
        "role" => %{
          "name" => "New Awesome Name",
          "permissions" => ["users.read", "users.update"]
        }
      })
      |> render_submit()

      assert_patch(lv, ~p"/admin/roles")

      {:ok, updated_role} = Roles.get_role(role.id)
      assert updated_role.name == "New Awesome Name"
      assert "users.update" in updated_role.permissions
    end

    test "does not render policy options for system permissions", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/admin/roles/new")

      lv
      |> form("#role-form", %{
        "role" => %{
          "name" => "System Admin",
          "permissions" => ["roles.read"]
        }
      })
      |> render_change()

      assert has_element?(lv, "input[name=\"role[permissions][]\"][value=\"roles.read\"]")

      refute has_element?(lv, "input[name=\"role[policies][roles.read][]\"]")
    end
  end
end
