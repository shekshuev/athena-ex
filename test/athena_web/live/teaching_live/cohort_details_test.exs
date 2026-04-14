defmodule AthenaWeb.TeachingLive.CohortDetailsTest do
  use AthenaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  import Athena.Factory
  alias Athena.Learning

  setup %{conn: conn} do
    role =
      insert(:role,
        permissions: [
          "cohorts.read",
          "cohorts.update",
          "enrollments.read",
          "enrollments.create",
          "enrollments.delete",
          "courses.read"
        ]
      )

    admin = insert(:account, role: role)
    conn = init_test_session(conn, %{"account_id" => admin.id})
    %{conn: conn, admin: admin}
  end

  describe "CohortDetails page (Index)" do
    test "should render cohort details, memberships, and enrollments", %{conn: conn} do
      cohort = insert(:cohort, name: "Spring Bootcamp")

      student = insert(:account, login: "test_student")
      {:ok, _membership} = Learning.add_student_to_cohort(cohort.id, student.id)

      course = insert(:course, title: "React Native")
      {:ok, _enrollment} = Learning.enroll_cohort(cohort.id, course.id)

      {:ok, _lv, html} = live(conn, ~p"/teaching/cohorts/#{cohort.id}")

      assert html =~ "Spring Bootcamp"
      assert html =~ "test_student"
      assert html =~ "React Native"
    end
  end

  describe "CohortDetails page (Add Actions)" do
    test "should open the add student slide-over via URL", %{conn: conn} do
      cohort = insert(:cohort)
      {:ok, _lv, html} = live(conn, ~p"/teaching/cohorts/#{cohort.id}/add_student")

      assert html =~ "Add Student to Cohort"
      assert html =~ "Search User by Login"
    end

    test "should open the assign course slide-over via URL", %{conn: conn} do
      cohort = insert(:cohort)
      {:ok, _lv, html} = live(conn, ~p"/teaching/cohorts/#{cohort.id}/enroll_course")

      assert html =~ "Assign Course to Cohort"
      assert html =~ "Search Course by Title"
    end
  end

  describe "CohortDetails page (Remove Actions)" do
    test "should delete a membership when confirmed", %{conn: conn} do
      cohort = insert(:cohort)
      student = insert(:account, login: "doomed_student")
      {:ok, membership} = Learning.add_student_to_cohort(cohort.id, student.id)

      {:ok, lv, _html} = live(conn, ~p"/teaching/cohorts/#{cohort.id}")

      lv
      |> element("button[phx-click='delete_click'][phx-value-id='#{membership.id}']")
      |> render_click()

      html = render_click(lv, "confirm_delete")

      assert html =~ "Student removed from cohort"
      refute html =~ "doomed_student"
    end

    test "should delete an enrollment when confirmed", %{conn: conn} do
      cohort = insert(:cohort)
      course = insert(:course, title: "Doomed Course")
      {:ok, enrollment} = Learning.enroll_cohort(cohort.id, course.id)

      {:ok, lv, _html} = live(conn, ~p"/teaching/cohorts/#{cohort.id}")

      lv
      |> element("button[phx-click='delete_enrollment_click'][phx-value-id='#{enrollment.id}']")
      |> render_click()

      html = render_click(lv, "confirm_delete_enrollment")

      assert html =~ "Course assignment removed"
      refute html =~ "Doomed Course"
    end
  end

  describe "Permissions & ACL" do
    setup %{conn: conn} do
      role = insert(:role, permissions: ["cohorts.read"])
      limited_user = insert(:account, role: role)
      conn = init_test_session(conn, %{"account_id" => limited_user.id})

      %{conn: conn, limited_user: limited_user}
    end

    test "should not see action buttons if user lacks permissions", %{conn: conn} do
      cohort = insert(:cohort)

      student = insert(:account)
      Learning.add_student_to_cohort(cohort.id, student.id)

      course = insert(:course)
      Learning.enroll_cohort(cohort.id, course.id)

      {:ok, _lv, html} = live(conn, ~p"/teaching/cohorts/#{cohort.id}")

      refute html =~ "hero-user-plus"
      refute html =~ "hero-book-open size-4"
      refute html =~ "hero-x-mark size-4"
    end

    test "should show error flash if user tries to trigger delete membership", %{conn: conn} do
      cohort = insert(:cohort)
      student = insert(:account)
      {:ok, membership} = Learning.add_student_to_cohort(cohort.id, student.id)

      {:ok, lv, _html} = live(conn, ~p"/teaching/cohorts/#{cohort.id}")

      html = render_click(lv, "delete_click", %{"id" => membership.id})

      assert html =~ "Permission denied"
    end

    test "should show error flash if user tries to trigger delete enrollment", %{conn: conn} do
      cohort = insert(:cohort)
      course = insert(:course)
      {:ok, enrollment} = Learning.enroll_cohort(cohort.id, course.id)

      {:ok, lv, _html} = live(conn, ~p"/teaching/cohorts/#{cohort.id}")

      html = render_click(lv, "delete_enrollment_click", %{"id" => enrollment.id})

      assert html =~ "Permission denied"
    end
  end
end
