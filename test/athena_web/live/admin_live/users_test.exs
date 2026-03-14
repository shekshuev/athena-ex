defmodule AthenaWeb.AdminLive.UsersTest do
  use AthenaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  import Athena.Factory

  describe "Users page (Index)" do
    setup %{conn: conn} do
      admin = insert(:account)
      conn = init_test_session(conn, %{"account_id" => admin.id})
      %{conn: conn, admin: admin}
    end

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
    setup %{conn: conn} do
      admin = insert(:account)
      conn = init_test_session(conn, %{"account_id" => admin.id})
      %{conn: conn}
    end

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
    setup %{conn: conn} do
      admin = insert(:account)
      conn = init_test_session(conn, %{"account_id" => admin.id})
      %{conn: conn}
    end

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
end
