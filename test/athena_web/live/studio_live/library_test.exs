defmodule AthenaWeb.StudioLive.LibraryTest do
  use AthenaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  import Athena.Factory

  setup %{conn: conn} do
    role =
      insert(:role,
        permissions: ["library.read", "library.create", "library.update", "library.delete"]
      )

    admin = insert(:account, role: role)
    conn = init_test_session(conn, %{"account_id" => admin.id})
    %{conn: conn, admin: admin}
  end

  describe "Library page (Index)" do
    test "should render the library templates list", %{conn: conn, admin: admin} do
      block = insert(:library_block, title: "Base Quiz Template", owner_id: admin.id)

      {:ok, _lv, html} = live(conn, ~p"/studio/library")

      assert html =~ "Library"
      assert html =~ "Create Template"
      assert html =~ block.title
    end

    test "should handle search functionality", %{conn: conn, admin: admin} do
      insert(:library_block, title: "Python Basics Exam", owner_id: admin.id)
      insert(:library_block, title: "Elixir Advanced", owner_id: admin.id)

      {:ok, lv, _html} = live(conn, ~p"/studio/library")

      html =
        lv
        |> form("form[phx-change='search']", %{"search" => "Python"})
        |> render_change()

      assert html =~ "Python Basics Exam"
      refute html =~ "Elixir Advanced"
    end
  end

  describe "Library page (Create/Edit actions)" do
    test "should open the create template slide-over via URL", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/studio/library/new")

      assert html =~ "Template Metadata"
      assert html =~ "Block Type"
      assert html =~ "Tags (comma separated)"
    end

    test "should open the edit template slide-over via URL", %{conn: conn, admin: admin} do
      block = insert(:library_block, title: "Target Template", owner_id: admin.id)

      {:ok, _lv, html} = live(conn, ~p"/studio/library/#{block.id}/edit")

      assert html =~ "Edit Template"
      assert html =~ "Target Template"
    end
  end

  describe "Library page (Delete action)" do
    test "should show confirmation modal on delete click", %{conn: conn, admin: admin} do
      block = insert(:library_block, title: "Doomed Template", owner_id: admin.id)

      {:ok, lv, _html} = live(conn, ~p"/studio/library")

      html =
        lv
        |> element("button[phx-click='delete_click'][phx-value-id='#{block.id}']")
        |> render_click()

      assert html =~ "Are you sure you want to permanently delete this template?"
    end

    test "should delete the template when confirmed", %{conn: conn, admin: admin} do
      block = insert(:library_block, title: "Doomed Template", owner_id: admin.id)

      {:ok, lv, _html} = live(conn, ~p"/studio/library")

      lv
      |> element("button[phx-click='delete_click'][phx-value-id='#{block.id}']")
      |> render_click()

      html = render_click(lv, "confirm_delete")

      assert html =~ "Template deleted successfully"
      refute html =~ "Doomed Template"
    end
  end

  describe "Permissions & ACL" do
    setup %{conn: conn} do
      role = insert(:role, permissions: ["library.read"])
      limited_user = insert(:account, role: role)
      conn = init_test_session(conn, %{"account_id" => limited_user.id})

      %{conn: conn, limited_user: limited_user}
    end

    test "should not see action buttons if user only has read permission", %{
      conn: conn,
      limited_user: user
    } do
      insert(:library_block, owner_id: user.id)
      {:ok, _lv, html} = live(conn, ~p"/studio/library")

      assert html =~ "Library"

      refute html =~ "Create Template"
      refute html =~ "hero-pencil-square"
      refute html =~ "hero-trash"
    end

    test "should redirect from /new if user lacks create permission", %{conn: conn} do
      {:error, {:live_redirect, %{to: "/studio/library"}}} = live(conn, ~p"/studio/library/new")
    end

    test "should redirect from /edit if user lacks update permission", %{
      conn: conn,
      limited_user: user
    } do
      target = insert(:library_block, owner_id: user.id)

      {:error, {:live_redirect, %{to: "/studio/library"}}} =
        live(conn, ~p"/studio/library/#{target.id}/edit")
    end

    test "should show error flash on delete_click if user lacks delete permission", %{
      conn: conn,
      limited_user: user
    } do
      target = insert(:library_block, owner_id: user.id)
      {:ok, lv, _html} = live(conn, ~p"/studio/library")

      html = render_click(lv, "delete_click", %{"id" => target.id})

      assert html =~ "You don&#39;t have permission to delete templates."
    end
  end
end
