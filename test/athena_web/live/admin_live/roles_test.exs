defmodule AthenaWeb.AdminLive.RolesTest do
  use AthenaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  import Athena.Factory

  describe "Roles page (Index)" do
    setup %{conn: conn} do
      admin = insert(:account)
      conn = init_test_session(conn, %{"account_id" => admin.id})

      %{conn: conn}
    end

    test "renders the roles list", %{conn: conn} do
      role = insert(:role, name: "Manager")

      {:ok, _lv, html} = live(conn, ~p"/admin/roles")

      assert html =~ "Roles &amp; Policies"
      assert html =~ "Create Role"
      assert html =~ role.name
    end

    test "handles search functionality", %{conn: conn} do
      insert(:role, name: "Editor")
      insert(:role, name: "Viewer")

      {:ok, lv, _html} = live(conn, ~p"/admin/roles")

      html =
        lv
        |> form("form[phx-change='search']", %{"search" => "Edit"})
        |> render_change()

      assert html =~ "Editor"
      refute html =~ "Viewer"
    end
  end

  describe "Roles page (Create/Edit actions)" do
    setup %{conn: conn} do
      admin = insert(:account)
      conn = init_test_session(conn, %{"account_id" => admin.id})
      %{conn: conn}
    end

    test "opens the create role slide-over via URL", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/admin/roles/new")

      assert html =~ "Role Name"
      assert html =~ "Permissions &amp; Policies"
    end

    test "opens the edit role slide-over via URL", %{conn: conn} do
      role = insert(:role, name: "SuperUser")

      {:ok, _lv, html} = live(conn, ~p"/admin/roles/#{role.id}/edit")

      assert html =~ "Edit Role"
      assert html =~ "SuperUser"
    end
  end

  describe "Roles page (Delete action)" do
    setup %{conn: conn} do
      admin = insert(:account)
      conn = init_test_session(conn, %{"account_id" => admin.id})
      %{conn: conn}
    end

    test "shows confirmation modal on delete click", %{conn: conn} do
      role = insert(:role, name: "Scammer")

      {:ok, lv, _html} = live(conn, ~p"/admin/roles")

      html =
        lv
        |> element("button[phx-click='delete_click'][phx-value-id='#{role.id}']")
        |> render_click()

      assert html =~ "Are you sure you want to delete this role?"
    end

    test "deletes the role when confirmed", %{conn: conn} do
      role = insert(:role, name: "DoomedRole")

      {:ok, lv, _html} = live(conn, ~p"/admin/roles")

      lv
      |> element("button[phx-click='delete_click'][phx-value-id='#{role.id}']")
      |> render_click()

      html = render_click(lv, "confirm_delete")

      assert html =~ "Role deleted successfully"
      refute html =~ "DoomedRole"
    end
  end
end
