defmodule AthenaWeb.TeachingLive.EnrollmentFormComponentTest do
  use AthenaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  import Athena.Factory
  alias Athena.Learning

  setup %{conn: conn} do
    role =
      insert(:role,
        permissions: [
          "cohorts.read",
          "enrollments.read",
          "enrollments.create",
          "courses.read"
        ]
      )

    account = insert(:account, role: role)

    conn = init_test_session(conn, %{"account_id" => account.id})
    %{conn: conn, current_user: account}
  end

  describe "Enrollment Form Component" do
    test "shows error when saving without selecting a course", %{conn: conn} do
      cohort = insert(:cohort)

      {:ok, lv, _html} = live(conn, ~p"/teaching/cohorts/#{cohort.id}/enroll_course")

      html =
        lv
        |> form("#enrollment-form")
        |> render_submit()

      assert html =~ "Please select a course."
    end

    test "searches and assigns a course to the cohort via autocomplete", %{
      conn: conn,
      current_user: current_user
    } do
      cohort = insert(:cohort)
      course = insert(:course, title: "Elixir Advanced Concepts")

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

      {:ok, {enrollments, _meta}} = Learning.list_cohort_enrollments(current_user, cohort.id, %{})
      assert length(enrollments) == 1
      assert hd(enrollments).course_id == course.id

      assert render(lv) =~ "Course successfully assigned"
    end

    test "shows error if the course is already assigned to the cohort", %{conn: conn} do
      cohort = insert(:cohort)
      course = insert(:course, title: "React Basics")

      {:ok, _enrollment} = Learning.enroll_cohort(cohort.id, course.id)

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
end
