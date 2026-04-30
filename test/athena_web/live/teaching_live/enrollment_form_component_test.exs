defmodule AthenaWeb.TeachingLive.EnrollmentFormComponentTest do
  use AthenaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  import Athena.Factory
  alias Athena.Learning

  setup %{conn: conn} do
    role =
      insert(:role,
        permissions: [
          "admin",
          "cohorts.read",
          "cohorts.update",
          "enrollments.read",
          "enrollments.create",
          "courses.read"
        ]
      )

    account = insert(:account, role: role)

    conn = init_test_session(conn, %{"account_id" => account.id})
    %{conn: conn, current_user: account, admin: account}
  end

  describe "Enrollment Form Component (Happy Path)" do
    test "shows error when saving without selecting a course", %{conn: conn, admin: admin} do
      cohort = insert(:cohort, owner_id: admin.id)

      {:ok, lv, _html} = live(conn, ~p"/teaching/cohorts/#{cohort.id}/enroll_course")

      html =
        lv
        |> form("#enrollment-form")
        |> render_submit()

      assert html =~ "Please select a course."
    end

    test "searches and assigns a course to the cohort via autocomplete", %{
      conn: conn,
      admin: admin
    } do
      cohort = insert(:cohort, owner_id: admin.id)
      course = insert(:course, title: "Elixir Advanced Concepts", owner_id: admin.id)

      {:ok, lv, _html} = live(conn, ~p"/teaching/cohorts/#{cohort.id}/enroll_course")

      lv
      |> element("input[phx-keyup='search_courses']")
      |> render_keyup(%{"value" => "Elixir Advanced"})

      lv
      |> element("li", "Elixir Advanced Concepts")
      |> render_click()

      lv
      |> form("#enrollment-form")
      |> render_submit()

      assert_patch(lv, ~p"/teaching/cohorts/#{cohort.id}")

      {:ok, {enrollments, _meta}} = Learning.list_cohort_enrollments(admin, cohort.id, %{})
      assert length(enrollments) == 1
      assert hd(enrollments).course_id == course.id

      assert render(lv) =~ "Course successfully assigned"
    end

    test "shows error if the course is already assigned to the cohort", %{
      conn: conn,
      admin: admin
    } do
      cohort = insert(:cohort, owner_id: admin.id)
      course = insert(:course, title: "React Basics", owner_id: admin.id)

      {:ok, _enrollment} = Learning.enroll_cohort(admin, cohort.id, course.id)

      {:ok, lv, _html} = live(conn, ~p"/teaching/cohorts/#{cohort.id}/enroll_course")

      lv
      |> element("input[phx-keyup='search_courses']")
      |> render_keyup(%{"value" => "React Basics"})

      lv
      |> element("li", "React Basics")
      |> render_click()

      html =
        lv
        |> form("#enrollment-form")
        |> render_submit()

      assert html =~ "This course is already assigned to this cohort."
    end
  end

  describe "Permissions & ACL (Policies: own_only)" do
    setup %{conn: conn} do
      role =
        insert(:role,
          permissions: [
            "cohorts.read",
            "cohorts.update",
            "enrollments.read",
            "enrollments.create",
            "courses.read"
          ],
          policies: %{
            "cohorts.update" => ["own_only"],
            "enrollments.create" => ["own_only"]
          }
        )

      instructor = insert(:account, role: role)
      conn = init_test_session(conn, %{"account_id" => instructor.id})

      %{conn: conn, instructor: instructor}
    end

    test "allows instructor to assign ANY course to a cohort THEY OWN", %{
      conn: conn,
      instructor: instructor
    } do
      my_cohort = insert(:cohort, owner_id: instructor.id)
      _other_course = insert(:course, title: "Hacking 101", owner_id: Ecto.UUID.generate())

      {:ok, lv, _html} = live(conn, ~p"/teaching/cohorts/#{my_cohort.id}/enroll_course")

      lv
      |> element("input[phx-keyup='search_courses']")
      |> render_keyup(%{"value" => "Hacking 101"})

      lv
      |> element("li", "Hacking 101")
      |> render_click()

      html =
        lv
        |> form("#enrollment-form")
        |> render_submit()

      assert html =~ "Course successfully assigned"
    end

    test "shows error if instructor tries to assign a course to a cohort they DON'T own, and they DON'T own the course",
         %{
           conn: conn
         } do
      other_cohort = insert(:cohort, owner_id: Ecto.UUID.generate())

      _other_course =
        insert(:course, title: "Forbidden Knowledge", owner_id: Ecto.UUID.generate())

      {:ok, lv, _html} = live(conn, ~p"/teaching/cohorts/#{other_cohort.id}/enroll_course")

      lv
      |> element("input[phx-keyup='search_courses']")
      |> render_keyup(%{"value" => "Forbidden Knowledge"})

      lv
      |> element("li", "Forbidden Knowledge")
      |> render_click()

      html =
        lv
        |> form("#enrollment-form")
        |> render_submit()

      assert html =~ "Permission denied."
    end
  end
end
