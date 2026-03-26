defmodule AthenaWeb.LearnLive.CourseTest do
  use AthenaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  import Athena.Factory

  setup %{conn: conn} do
    user = insert(:account)
    conn = init_test_session(conn, %{"account_id" => user.id})
    %{conn: conn, user: user}
  end

  describe "Course Syllabus Page" do
    test "renders course title and syllabus if student has access", %{conn: conn, user: user} do
      course = insert(:course, title: "Secret Course", description: "A test course description")

      insert(:enrollment, account_id: user.id, course_id: course.id)

      insert(:section, course: course, title: "Module 1: Basics", visibility: :public)

      {:ok, _lv, html} = live(conn, ~p"/learn/courses/#{course.id}")

      assert html =~ "Secret Course"
      assert html =~ "A test course description"
      assert html =~ "Continue Learning"
      assert html =~ "Module 1: Basics"
    end

    test "redirects to dashboard with error if student has NO access", %{conn: conn} do
      course = insert(:course)

      {:error, {:live_redirect, %{to: "/learn", flash: flash}}} =
        live(conn, ~p"/learn/courses/#{course.id}")

      assert flash["error"] == "Access denied."
    end

    test "redirects to dashboard if course is deleted", %{conn: conn, user: user} do
      course = insert(:course, deleted_at: DateTime.utc_now())

      insert(:enrollment, account_id: user.id, course_id: course.id)

      {:error, {:live_redirect, %{to: "/learn", flash: flash}}} =
        live(conn, ~p"/learn/courses/#{course.id}")

      assert flash["error"] == "Access denied."
    end
  end
end
