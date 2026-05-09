defmodule AthenaWeb.AdminLive.RolesTest do
  use AthenaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  import Athena.Factory

  setup %{conn: conn} do
    role =
      insert(:role,
        permissions: ["admin", "roles.read", "roles.create", "roles.update", "roles.delete"]
      )

    admin = insert(:account, role: role)
    conn = init_test_session(conn, %{"account_id" => admin.id})
    %{conn: conn, admin: admin}
  end

  describe "Roles page (Index)" do
    test "renders the roles list", %{conn: conn, admin: admin} do
      {:ok, _lv, html} = live(conn, ~p"/admin/roles")

      assert html =~ "Roles &amp; Policies"
      assert html =~ "Create Role"
      assert html =~ admin.role.name
    end

    test "handles search functionality and maintains params", %{conn: conn} do
      insert(:role, name: "SpecialEditor")
      insert(:role, name: "CommonViewer")

      {:ok, lv, _html} = live(conn, ~p"/admin/roles")

      html =
        lv
        |> form("form[phx-change='search']", %{"search" => "Special"})
        |> render_change()

      assert html =~ "SpecialEditor"
      refute html =~ "CommonViewer"

      assert_patched(
        lv,
        ~p"/admin/roles?order_by[]=name&order_directions[]=asc&page=1&page_size=10&search=Special"
      )
    end
  end

  describe "Roles page (Pagination & Sorting)" do
    test "changes page size and updates URL", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/admin/roles")

      lv
      |> form("form[phx-change='update_page_size']", %{"page_size" => "50"})
      |> render_change()

      assert_patched(
        lv,
        ~p"/admin/roles?order_by[]=name&order_directions[]=asc&page=1&page_size=50"
      )
    end

    test "sorts by inserted_at when column header is clicked", %{conn: conn} do
      insert(:role, name: "ZuluRole")
      insert(:role, name: "AlphaRole")

      {:ok, lv, _html} = live(conn, ~p"/admin/roles")

      lv
      |> element("a", "Created At")
      |> render_click()

      assert_patched(
        lv,
        ~p"/admin/roles?order_by[]=inserted_at&order_directions[]=asc&page=1&page_size=10"
      )
    end
  end

  describe "Roles page (Create/Edit actions)" do
    test "opens the create role slide-over via URL and preserves params", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/admin/roles/new?page_size=20&search=test")

      assert html =~ "Role Name"
      assert html =~ "Permissions &amp; Policies"
    end

    test "opens the edit role slide-over via URL and preserves params", %{conn: conn} do
      target_role = insert(:role, name: "TargetRole")

      {:ok, _lv, html} = live(conn, ~p"/admin/roles/#{target_role.id}/edit?page_size=50")

      assert html =~ "Edit Role"
      assert html =~ "TargetRole"
    end
  end

  describe "Roles page (Delete action)" do
    test "shows confirmation modal on delete click", %{conn: conn} do
      target_role = insert(:role, name: "ScamRole")

      {:ok, lv, _html} = live(conn, ~p"/admin/roles")

      html =
        lv
        |> element("button[phx-click='delete_click'][phx-value-id='#{target_role.id}']")
        |> render_click()

      assert html =~ "Are you sure you want to delete this role? This action cannot be undone."
    end

    test "deletes the role when confirmed", %{conn: conn} do
      target_role = insert(:role, name: "DoomedRole")

      {:ok, lv, _html} = live(conn, ~p"/admin/roles")

      lv
      |> element("button[phx-click='delete_click'][phx-value-id='#{target_role.id}']")
      |> render_click()

      html = render_click(lv, "confirm_delete")

      assert html =~ "Role deleted successfully"
      refute html =~ "DoomedRole"
    end
  end

  describe "Permissions & ACL" do
    setup %{conn: conn} do
      role = insert(:role, permissions: ["roles.read"])
      limited_user = insert(:account, role: role)
      conn = init_test_session(conn, %{"account_id" => limited_user.id})

      %{conn: conn, limited_user: limited_user}
    end

    test "user with only read permission cannot see action buttons", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/admin/roles")

      assert html =~ "Roles &amp; Policies"

      refute html =~ "Create Role"
      refute html =~ "hero-pencil-square"
      refute html =~ "hero-trash"
    end

    test "user without create permission is redirected from /new", %{conn: conn} do
      {:error, {:live_redirect, %{to: "/admin/roles"}}} = live(conn, ~p"/admin/roles/new")
    end

    test "user without update permission is redirected from /edit", %{conn: conn} do
      target = insert(:role)

      {:error, {:live_redirect, %{to: "/admin/roles"}}} =
        live(conn, ~p"/admin/roles/#{target.id}/edit")
    end

    test "user without delete permission cannot trigger delete_click", %{conn: conn} do
      target = insert(:role)
      {:ok, lv, _html} = live(conn, ~p"/admin/roles")

      html = render_click(lv, "delete_click", %{"id" => target.id})

      assert html =~ "You don&#39;t have permission to delete roles."
    end
  end
end
