defmodule AthenaWeb.StudioLive.CoursesTest do
  use AthenaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  import Athena.Factory

  setup %{conn: conn} do
    role =
      insert(:role,
        permissions: ["courses.read", "courses.create", "courses.update", "courses.delete"]
      )

    admin = insert(:account, role: role)
    conn = init_test_session(conn, %{"account_id" => admin.id})
    %{conn: conn, admin: admin}
  end

  describe "Courses page (Index)" do
    test "should render the courses list", %{conn: conn} do
      course = insert(:course, title: "Mastering Elixir")

      {:ok, _lv, html} = live(conn, ~p"/studio/courses")

      assert html =~ "Courses"
      assert html =~ "Create Course"
      assert html =~ course.title
    end

    test "should handle search functionality", %{conn: conn} do
      insert(:course, title: "Phoenix LiveView Guide")
      insert(:course, title: "PostgreSQL Basics")

      {:ok, lv, _html} = live(conn, ~p"/studio/courses")

      html =
        lv
        |> form("form[phx-change='search']", %{"search" => "Phoenix"})
        |> render_change()

      assert html =~ "Phoenix LiveView Guide"
      refute html =~ "PostgreSQL Basics"
    end

    test "search functionality is case-insensitive", %{conn: conn} do
      insert(:course, title: "Elixir Masterclass")
      {:ok, lv, _html} = live(conn, ~p"/studio/courses")

      html =
        lv
        |> form("form[phx-change='search']", %{"search" => "elixir"})
        |> render_change()

      assert html =~ "Elixir Masterclass"
    end

    test "does not render soft-deleted courses in the list", %{conn: conn} do
      insert(:course, title: "Active Course")
      insert(:course, title: "Deleted Course", deleted_at: DateTime.utc_now())

      {:ok, _lv, html} = live(conn, ~p"/studio/courses")

      assert html =~ "Active Course"
      refute html =~ "Deleted Course"
    end
  end

  describe "Courses page (Create/Edit actions)" do
    test "should open the create course slide-over via URL", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/studio/courses/new")

      assert html =~ "Course Settings"
      assert html =~ "Visibility Status"
    end

    test "should open the edit course slide-over via URL", %{conn: conn} do
      course = insert(:course, title: "Target Course")

      {:ok, _lv, html} = live(conn, ~p"/studio/courses/#{course.id}/edit")

      assert html =~ "Edit Course"
      assert html =~ "Target Course"
    end
  end

  describe "Courses page (Delete action)" do
    test "should show confirmation modal on delete click", %{conn: conn} do
      course = insert(:course, title: "Doomed Course")

      {:ok, lv, _html} = live(conn, ~p"/studio/courses")

      html =
        lv
        |> element("button[phx-click='delete_click'][phx-value-id='#{course.id}']")
        |> render_click()

      assert html =~ "Are you sure you want to move this course to the archive?"
    end

    test "should delete the course when confirmed", %{conn: conn} do
      course = insert(:course, title: "Doomed Course")

      {:ok, lv, _html} = live(conn, ~p"/studio/courses")

      lv
      |> element("button[phx-click='delete_click'][phx-value-id='#{course.id}']")
      |> render_click()

      html = render_click(lv, "confirm_delete")

      assert html =~ "Course deleted successfully"
      refute html =~ "Doomed Course"
    end
  end

  describe "Permissions & ACL" do
    setup %{conn: conn} do
      role = insert(:role, permissions: ["courses.read"])
      limited_user = insert(:account, role: role)
      conn = init_test_session(conn, %{"account_id" => limited_user.id})

      %{conn: conn, limited_user: limited_user}
    end

    test "should not see action buttons if user only has read permission", %{conn: conn} do
      insert(:course)
      {:ok, _lv, html} = live(conn, ~p"/studio/courses")

      assert html =~ "Courses"

      refute html =~ "Create Course"
      refute html =~ "hero-pencil-square"
      refute html =~ "hero-trash"
      refute html =~ "hero-wrench-screwdriver"
    end

    test "should redirect from /new if user lacks create permission", %{conn: conn} do
      {:error, {:live_redirect, %{to: "/studio/courses"}}} = live(conn, ~p"/studio/courses/new")
    end

    test "should redirect from /edit if user lacks update permission", %{conn: conn} do
      target = insert(:course)

      {:error, {:live_redirect, %{to: "/studio/courses"}}} =
        live(conn, ~p"/studio/courses/#{target.id}/edit")
    end

    test "should show error flash on delete_click if user lacks delete permission", %{conn: conn} do
      target = insert(:course)
      {:ok, lv, _html} = live(conn, ~p"/studio/courses")

      html = render_click(lv, "delete_click", %{"id" => target.id})

      assert html =~ "You don&#39;t have permission to delete courses."
    end

    test "should redirect from /edit if user has own_only policy and tries to edit another user's course",
         %{conn: conn} do
      role =
        insert(:role,
          permissions: ["courses.read", "courses.update"],
          policies: %{
            "courses.read" => ["own_only"],
            "courses.update" => ["own_only"]
          }
        )

      instructor = insert(:account, role: role)
      instructor_conn = init_test_session(conn, %{"account_id" => instructor.id})

      other_user = insert(:account)
      target_course = insert(:course, owner_id: other_user.id)

      {:error, {:live_redirect, %{to: "/studio/courses"}}} =
        live(instructor_conn, ~p"/studio/courses/#{target_course.id}/edit")
    end
  end
end
