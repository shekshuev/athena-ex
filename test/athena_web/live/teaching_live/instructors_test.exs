defmodule AthenaWeb.TeachingLive.InstructorsTest do
  use AthenaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  import Athena.Factory

  setup %{conn: conn} do
    role =
      insert(:role,
        permissions: [
          "instructors.read",
          "instructors.create",
          "instructors.update",
          "instructors.delete"
        ]
      )

    admin = insert(:account, role: role)
    conn = init_test_session(conn, %{"account_id" => admin.id})
    %{conn: conn, admin: admin}
  end

  describe "Instructors page (Index)" do
    test "should render the instructors list", %{conn: conn} do
      instructor = insert(:instructor, title: "Head of Elixir Department")

      {:ok, _lv, html} = live(conn, ~p"/teaching/instructors")

      assert html =~ "Instructors"
      assert html =~ "Add Instructor"
      assert html =~ instructor.title
    end

    test "should handle search functionality", %{conn: conn} do
      insert(:instructor, title: "Senior Phoenix Dev")
      insert(:instructor, title: "Junior React Dev")

      {:ok, lv, _html} = live(conn, ~p"/teaching/instructors")

      html =
        lv
        |> form("form[phx-change='search']", %{"search" => "Phoenix"})
        |> render_change()

      assert html =~ "Senior Phoenix Dev"
      refute html =~ "Junior React Dev"
    end
  end

  describe "Instructors page (Create/Edit actions)" do
    test "should open the create instructor slide-over via URL", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/teaching/instructors/new")

      assert html =~ "Create Instructor"
      assert html =~ "User Account"
    end

    test "should open the edit instructor slide-over via URL", %{conn: conn} do
      instructor = insert(:instructor, title: "Target Instructor")

      {:ok, _lv, html} = live(conn, ~p"/teaching/instructors/#{instructor.id}/edit")

      assert html =~ "Edit Instructor"
      assert html =~ "Target Instructor"
    end
  end

  describe "Instructors page (Delete action)" do
    test "should show confirmation modal on delete click", %{conn: conn} do
      instructor = insert(:instructor, title: "Doomed Instructor")

      {:ok, lv, _html} = live(conn, ~p"/teaching/instructors")

      html =
        lv
        |> element("button[phx-click='delete_click'][phx-value-id='#{instructor.id}']")
        |> render_click()

      assert html =~ "Are you sure you want to remove this instructor profile?"
    end

    test "should delete the instructor when confirmed", %{conn: conn} do
      instructor = insert(:instructor, title: "Doomed Instructor")

      {:ok, lv, _html} = live(conn, ~p"/teaching/instructors")

      lv
      |> element("button[phx-click='delete_click'][phx-value-id='#{instructor.id}']")
      |> render_click()

      html = render_click(lv, "confirm_delete")

      assert html =~ "Instructor deleted successfully"
      refute html =~ "Doomed Instructor"
    end
  end

  describe "Permissions & ACL" do
    setup %{conn: conn} do
      role = insert(:role, permissions: ["instructors.read"])
      limited_user = insert(:account, role: role)
      conn = init_test_session(conn, %{"account_id" => limited_user.id})

      %{conn: conn, limited_user: limited_user}
    end

    test "should not see action buttons if user only has read permission", %{conn: conn} do
      insert(:instructor)
      {:ok, _lv, html} = live(conn, ~p"/teaching/instructors")

      assert html =~ "Instructors"

      refute html =~ "Add Instructor"
      refute html =~ "hero-pencil-square"
      refute html =~ "hero-trash"
    end

    test "should redirect from /new if user lacks create permission", %{conn: conn} do
      {:error, {:live_redirect, %{to: "/teaching/instructors"}}} =
        live(conn, ~p"/teaching/instructors/new")
    end

    test "should redirect from /edit if user lacks update permission", %{conn: conn} do
      target = insert(:instructor)

      {:error, {:live_redirect, %{to: "/teaching/instructors"}}} =
        live(conn, ~p"/teaching/instructors/#{target.id}/edit")
    end

    test "should show error flash on delete_click if user lacks delete permission", %{conn: conn} do
      target = insert(:instructor)
      {:ok, lv, _html} = live(conn, ~p"/teaching/instructors")

      html = render_click(lv, "delete_click", %{"id" => target.id})

      assert html =~ "You don&#39;t have permission to delete instructors."
    end
  end
end
