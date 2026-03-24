defmodule AthenaWeb.LearnLive.CourseTest do
  use AthenaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  import Athena.Factory
  alias Athena.Learning.Enrollment

  setup %{conn: conn} do
    student = insert(:account)
    conn = init_test_session(conn, %{"account_id" => student.id})
    %{conn: conn, student: student}
  end

  describe "Course Syllabus Page" do
    test "renders course title and syllabus if student has access", %{
      conn: conn,
      student: student
    } do
      course = insert(:course, title: "Secret Course")

      insert(:section, course: course, title: "Module 1: Basics")

      %Enrollment{}
      |> Enrollment.changeset(%{account_id: student.id, course_id: course.id, status: :active})
      |> Athena.Repo.insert!()

      {:ok, _lv, html} = live(conn, ~p"/learn/courses/#{course.id}")

      assert html =~ "Secret Course"
      assert html =~ "Module 1: Basics"
      assert html =~ "Start Learning"
    end

    test "redirects to dashboard with error if student has NO access", %{conn: conn} do
      course = insert(:course)

      {:error, {:live_redirect, %{to: "/learn", flash: flash}}} =
        live(conn, ~p"/learn/courses/#{course.id}")

      assert flash["error"] == "You don't have access to this course."
    end

    test "redirects to dashboard if course is deleted", %{conn: conn, student: student} do
      deleted_course = insert(:course, deleted_at: DateTime.utc_now())

      %Enrollment{}
      |> Enrollment.changeset(%{
        account_id: student.id,
        course_id: deleted_course.id,
        status: :active
      })
      |> Athena.Repo.insert!()

      {:error, {:live_redirect, %{to: "/learn", flash: flash}}} =
        live(conn, ~p"/learn/courses/#{deleted_course.id}")

      assert flash["error"] == "Course not found."
    end
  end
end
