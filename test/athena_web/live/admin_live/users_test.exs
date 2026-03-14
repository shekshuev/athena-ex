defmodule AthenaWeb.AdminLive.UsersTest do
  use AthenaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  import Athena.Factory

  setup %{conn: conn} do
    role = insert(:role, permissions: ["admin"])
    admin = insert(:account, role: role)
    conn = init_test_session(conn, %{"account_id" => admin.id})
    %{conn: conn, admin: admin}
  end

  describe "Users page (Index)" do
    test "renders the users list", %{conn: conn, admin: admin} do
      {:ok, _lv, html} = live(conn, ~p"/admin/users")

      assert html =~ "Users"
      assert html =~ "Create User"
      assert html =~ admin.login
    end

    test "handles search functionality", %{conn: conn} do
      insert(:account, login: "editor_dude")
      insert(:account, login: "viewer_bro")

      {:ok, lv, _html} = live(conn, ~p"/admin/users")

      html =
        lv
        |> form("form[phx-change='search']", %{"search" => "editor"})
        |> render_change()

      assert html =~ "editor_dude"
      refute html =~ "viewer_bro"
    end
  end

  describe "Users page (Create/Edit actions)" do
    test "opens the create user slide-over via URL", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/admin/users/new")

      assert html =~ "Account Access"
      assert html =~ "Personal Information"
    end

    test "opens the edit user slide-over via URL", %{conn: conn} do
      account = insert(:account, login: "target_user")

      {:ok, _lv, html} = live(conn, ~p"/admin/users/#{account.id}/edit")

      assert html =~ "Edit User"
      assert html =~ "target_user"
    end
  end

  describe "Users page (Delete action)" do
    test "shows confirmation modal on delete click", %{conn: conn} do
      account = insert(:account, login: "scammer_boy")

      {:ok, lv, _html} = live(conn, ~p"/admin/users")

      html =
        lv
        |> element("button[phx-click='delete_click'][phx-value-id='#{account.id}']")
        |> render_click()

      assert html =~
               "Are you sure you want to delete this account? This will also block profile access."
    end

    test "deletes the user when confirmed", %{conn: conn} do
      account = insert(:account, login: "doomed_user")

      {:ok, lv, _html} = live(conn, ~p"/admin/users")

      lv
      |> element("button[phx-click='delete_click'][phx-value-id='#{account.id}']")
      |> render_click()

      html = render_click(lv, "confirm_delete")

      assert html =~ "Account deleted successfully"
      refute html =~ "doomed_user"
    end
  end

  describe "Permissions & ACL" do
    setup %{conn: conn} do
      role = insert(:role, permissions: ["users.read"])
      limited_user = insert(:account, role: role)
      conn = init_test_session(conn, %{"account_id" => limited_user.id})

      %{conn: conn, limited_user: limited_user}
    end

    test "user with only read permission cannot see action buttons", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/admin/users")

      assert html =~ "Users"

      refute html =~ "Create User"
      refute html =~ "hero-pencil-square"
      refute html =~ "hero-trash"
    end

    test "user without create permission is redirected from /new", %{conn: conn} do
      {:error, {:live_redirect, %{to: "/admin/users"}}} = live(conn, ~p"/admin/users/new")
    end

    test "user without update permission is redirected from /edit", %{conn: conn} do
      target = insert(:account)

      {:error, {:live_redirect, %{to: "/admin/users"}}} =
        live(conn, ~p"/admin/users/#{target.id}/edit")
    end

    test "user without delete permission cannot trigger delete_click", %{conn: conn} do
      target = insert(:account)
      {:ok, lv, _html} = live(conn, ~p"/admin/users")

      html = render_click(lv, "delete_click", %{"id" => target.id})

      assert html =~ "You don&#39;t have permission to delete users."
    end
  end
end
