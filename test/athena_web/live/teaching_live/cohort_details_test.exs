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
          "courses.read"
        ]
      )

    admin = insert(:account, role: role)
    conn = init_test_session(conn, %{"account_id" => admin.id})
    %{conn: conn, admin: admin}
  end

  describe "CohortDetails page (Index)" do
    test "should render cohort details, memberships, enrollments and access button", %{
      conn: conn,
      admin: admin
    } do
      cohort = insert(:cohort, name: "Spring Bootcamp", owner_id: admin.id)

      student = insert(:account, login: "test_student")
      {:ok, _membership} = Learning.add_student_to_cohort(cohort.id, student.id)

      course = insert(:course, title: "React Native", owner_id: admin.id)
      {:ok, _enrollment} = Learning.enroll_cohort(admin, cohort.id, course.id)

      {:ok, _lv, html} = live(conn, ~p"/teaching/cohorts/#{cohort.id}")

      assert html =~ "Spring Bootcamp"
      assert html =~ "test_student"
      assert html =~ "React Native"

      assert html =~ "Access"
      assert html =~ "/teaching/cohorts/#{cohort.id}/access/#{course.id}"
    end
  end

  describe "CohortDetails page (Add Actions)" do
    test "should open the add student slide-over via URL", %{conn: conn, admin: admin} do
      cohort = insert(:cohort, owner_id: admin.id)
      {:ok, _lv, html} = live(conn, ~p"/teaching/cohorts/#{cohort.id}/add_student")

      assert html =~ "Add Student to Cohort"
      assert html =~ "Search User by Login"
    end

    test "should open the assign course slide-over via URL", %{conn: conn, admin: admin} do
      cohort = insert(:cohort, owner_id: admin.id)
      {:ok, _lv, html} = live(conn, ~p"/teaching/cohorts/#{cohort.id}/enroll_course")

      assert html =~ "Assign Course to Cohort"
      assert html =~ "Search Course by Title"
    end
  end

  describe "CohortDetails page (Remove Actions)" do
    test "should delete a membership when confirmed", %{conn: conn, admin: admin} do
      cohort = insert(:cohort, owner_id: admin.id)
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

    test "should delete an enrollment when confirmed", %{conn: conn, admin: admin} do
      cohort = insert(:cohort, owner_id: admin.id)
      course = insert(:course, title: "Doomed Course", owner_id: admin.id)
      {:ok, enrollment} = Learning.enroll_cohort(admin, cohort.id, course.id)

      {:ok, lv, _html} = live(conn, ~p"/teaching/cohorts/#{cohort.id}")

      lv
      |> element("button[phx-click='delete_enrollment_click'][phx-value-id='#{enrollment.id}']")
      |> render_click()

      html = render_click(lv, "confirm_delete_enrollment")

      assert html =~ "Course assignment removed"
      refute html =~ "Doomed Course"
    end
  end

  describe "Permissions & ACL (Missing Permissions)" do
    setup %{conn: conn} do
      role = insert(:role, permissions: ["cohorts.read"])
      limited_user = insert(:account, role: role)
      conn = init_test_session(conn, %{"account_id" => limited_user.id})

      %{conn: conn, limited_user: limited_user}
    end

    test "should not see action buttons if user lacks permissions", %{conn: conn} do
      super_admin = insert(:account, role: insert(:role, permissions: ["admin"]))

      cohort = insert(:cohort)
      student = insert(:account)
      Learning.add_student_to_cohort(cohort.id, student.id)

      course = insert(:course)
      Learning.enroll_cohort(super_admin, cohort.id, course.id)

      {:ok, _lv, html} = live(conn, ~p"/teaching/cohorts/#{cohort.id}")

      refute html =~ "hero-user-plus"
      refute html =~ "hero-book-open size-4"
      refute html =~ "phx-click=\"delete_click\""
    end

    test "should show error flash if user tries to trigger delete membership", %{conn: conn} do
      cohort = insert(:cohort)
      student = insert(:account)
      {:ok, membership} = Learning.add_student_to_cohort(cohort.id, student.id)

      {:ok, lv, _html} = live(conn, ~p"/teaching/cohorts/#{cohort.id}")

      html = render_click(lv, "delete_click", %{"id" => membership.id})

      assert html =~ "Permission denied"
    end
  end

  describe "Permissions & ACL (Policies: own_only)" do
    setup %{conn: conn} do
      role =
        insert(:role,
          permissions: [
            "cohorts.read",
            "cohorts.update",
            "courses.read"
          ],
          policies: %{
            "cohorts.read" => ["own_only"],
            "cohorts.update" => ["own_only"],
            "courses.read" => ["own_only"]
          }
        )

      instructor = insert(:account, role: role)
      inst_profile = insert(:instructor, owner_id: instructor.id)
      conn = init_test_session(conn, %{"account_id" => instructor.id})

      %{conn: conn, instructor: instructor, inst_profile: inst_profile}
    end

    test "shows action buttons ONLY for owned cohorts and enrollments", %{
      conn: conn,
      instructor: instructor
    } do
      my_cohort = insert(:cohort, owner_id: instructor.id)

      student = insert(:account)
      {:ok, my_membership} = Learning.add_student_to_cohort(my_cohort.id, student.id)

      my_course = insert(:course, owner_id: instructor.id)
      {:ok, my_enrollment} = Learning.enroll_cohort(instructor, my_cohort.id, my_course.id)

      {:ok, _lv, my_html} = live(conn, ~p"/teaching/cohorts/#{my_cohort.id}")

      assert my_html =~ ~p"/teaching/cohorts/#{my_cohort.id}/add_student"
      assert my_html =~ ~s(phx-value-id="#{my_membership.id}")
      assert my_html =~ ~s(phx-value-id="#{my_enrollment.id}")
    end

    test "shows action buttons for cohort if user is co-instructor", %{
      conn: conn,
      inst_profile: inst_profile
    } do
      super_admin = insert(:account, role: insert(:role, permissions: ["admin"]))
      shared_cohort = insert(:cohort, owner_id: super_admin.id)

      Learning.update_cohort(super_admin, shared_cohort, %{
        "instructor_ids" => [inst_profile.id]
      })

      {:ok, _lv, html} = live(conn, ~p"/teaching/cohorts/#{shared_cohort.id}")

      assert html =~ ~p"/teaching/cohorts/#{shared_cohort.id}/add_student"
    end

    test "redirects on mount if trying to access someone else's cohort without rights", %{
      conn: conn
    } do
      other_cohort = insert(:cohort, owner_id: Ecto.UUID.generate())

      assert {:error, {:live_redirect, %{to: to}}} =
               live(conn, ~p"/teaching/cohorts/#{other_cohort.id}")

      assert to == "/teaching/cohorts"
    end

    test "redirects with error if forcing add_student on someone else's cohort", %{conn: conn} do
      other_cohort = insert(:cohort, owner_id: Ecto.UUID.generate())

      assert {:error, {:live_redirect, %{to: to}}} =
               live(conn, ~p"/teaching/cohorts/#{other_cohort.id}/add_student")

      assert to == "/teaching/cohorts"
    end
  end
end
