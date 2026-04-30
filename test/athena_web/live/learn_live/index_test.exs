defmodule AthenaWeb.LearnLive.IndexTest do
  use AthenaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  import Athena.Factory

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

      insert(:cohort_membership, account_id: student.id, cohort_id: cohort.id)
      insert(:enrollment, cohort_id: cohort.id, course_id: course_cohort.id)

      {:ok, _lv, html} = live(conn, ~p"/learn")

      refute html =~ "No courses yet"

      assert html =~ "Direct Intro to Elixir"
      assert html =~ "Cohort Advanced OTP"

      assert html =~ cohort.name
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

    test "displays multiple cards for the same course if enrolled via different cohorts", %{
      conn: conn,
      student: student
    } do
      course = insert(:course, title: "Database Systems")

      cohort_radio = insert(:cohort, name: "Radio Squad")
      cohort_cyber = insert(:cohort, name: "Cyber Squad")

      insert(:cohort_membership, account_id: student.id, cohort_id: cohort_radio.id)
      insert(:cohort_membership, account_id: student.id, cohort_id: cohort_cyber.id)

      insert(:enrollment, cohort_id: cohort_radio.id, course_id: course.id)
      insert(:enrollment, cohort_id: cohort_cyber.id, course_id: course.id)

      {:ok, _lv, html} = live(conn, ~p"/learn")

      assert html =~ "Database Systems"
      assert html =~ "Radio Squad"
      assert html =~ "Cyber Squad"

      assert html =~ ~s("/learn/courses/#{course.id}")
    end
  end
end
