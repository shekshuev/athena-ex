defmodule AthenaWeb.LearnLive.IndexTest do
  use AthenaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  import Athena.Factory
  alias Athena.Learning.Enrollments
  alias Athena.Learning.Cohorts

  setup %{conn: conn} do
    student = insert(:account)
    conn = init_test_session(conn, %{"account_id" => student.id})
    %{conn: conn, student: student}
  end

  describe "Student Dashboard" do
    test "displays empty state when student has no enrollments", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/learn")

      assert html =~ "My Learning"
      assert html =~ "No courses yet"
      assert html =~ "You are not enrolled in any courses"
    end

    test "displays courses enrolled directly and via cohort", %{conn: conn, student: student} do
      course_direct = insert(:course, title: "Direct Intro to Elixir")
      course_cohort = insert(:course, title: "Cohort Advanced OTP")

      insert(:enrollment, account_id: student.id, course_id: course_direct.id)

      cohort = insert(:cohort)
      Cohorts.add_student_to_cohort(cohort.id, student.id)
      Enrollments.enroll_cohort(cohort.id, course_cohort.id)

      {:ok, _lv, html} = live(conn, ~p"/learn")

      refute html =~ "No courses yet"

      assert html =~ "Direct Intro to Elixir"
      assert html =~ "Cohort Advanced OTP"

      assert html =~ "Academic Cohort"
      assert html =~ "Self-paced"

      assert html =~ "/learn/courses/#{course_direct.id}"
      assert html =~ "/learn/courses/#{course_cohort.id}"
    end

    test "does not display soft-deleted courses", %{conn: conn, student: student} do
      deleted_course = insert(:course, title: "Ghost Course", deleted_at: DateTime.utc_now())

      insert(:enrollment, account_id: student.id, course_id: deleted_course.id)

      {:ok, _lv, html} = live(conn, ~p"/learn")

      assert html =~ "No courses yet"
      refute html =~ "Ghost Course"
    end
  end
end
