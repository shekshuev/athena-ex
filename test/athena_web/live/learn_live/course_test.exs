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

    test "displays locked sections with restricted access", %{conn: conn, user: user} do
      course = insert(:course)
      insert(:enrollment, account_id: user.id, course_id: course.id)

      s1 = insert(:section, course: course, title: "Module 1", order: 1)
      insert(:block, section: s1, completion_rule: %Athena.Content.CompletionRule{type: :button})

      insert(:section, course: course, title: "Module 2: Advanced", order: 2)

      {:ok, _lv, html} = live(conn, ~p"/learn/courses/#{course.id}")

      assert html =~ "Module 1"
      assert html =~ "Module 2: Advanced"

      assert html =~ "hero-lock-closed"
      assert html =~ "opacity-40 pointer-events-none"
    end

    test "navigates down into a folder (drill-down navigation)", %{conn: conn, user: user} do
      course = insert(:course)
      insert(:enrollment, account_id: user.id, course_id: course.id)

      folder = insert(:section, course: course, title: "Chapter 1 (Folder)")
      insert(:section, course: course, title: "Lesson 1", parent_id: folder.id)

      {:ok, _lv, html} = live(conn, ~p"/learn/courses/#{course.id}")

      assert html =~ "Chapter 1 (Folder)"
      refute html =~ "Lesson 1"

      {:ok, _lv, html_folder} = live(conn, ~p"/learn/courses/#{course.id}?parent_id=#{folder.id}")

      assert html_folder =~ "Lesson 1"
      assert html_folder =~ "hero-chevron-right"
      assert html_folder =~ "Chapter 1 (Folder)"
    end

    test "handles real-time content refresh via PubSub", %{conn: conn, user: user} do
      course = insert(:course)
      insert(:enrollment, account_id: user.id, course_id: course.id)

      {:ok, lv, html} = live(conn, ~p"/learn/courses/#{course.id}")
      assert html =~ "This section is empty."

      insert(:section, course: course, title: "Live Added Module")

      send(lv.pid, :refresh_content)

      assert render(lv) =~ "Live Added Module"
    end
  end
end
