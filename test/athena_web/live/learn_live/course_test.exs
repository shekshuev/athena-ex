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

      s1 = insert(:section, course: course, title: "Module 1: Basics", visibility: :enrolled)

      insert(:block, section: nil, section_id: s1.id)

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
      child = insert(:section, course: course, title: "Lesson 1", parent_id: folder.id)

      insert(:block, section: nil, section_id: child.id)

      {:ok, _lv, html} = live(conn, ~p"/learn/courses/#{course.id}")

      assert html =~ "Chapter 1 (Folder)"
      refute html =~ "Lesson 1"

      {:ok, _lv, html_folder} = live(conn, ~p"/learn/courses/#{course.id}?parent_id=#{folder.id}")

      assert html_folder =~ "Lesson 1"
      assert html_folder =~ "hero-chevron-right"
      assert html_folder =~ "Chapter 1 (Folder)"

      assert html_folder =~ "Course Home"
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

    test "shows leaderboard button only for competition courses", %{conn: conn, user: user} do
      comp_course = insert(:course, title: "Team CTF", type: :competition)
      insert(:enrollment, account_id: user.id, course_id: comp_course.id)

      {:ok, _lv_comp, html_comp} = live(conn, ~p"/learn/courses/#{comp_course.id}")

      assert html_comp =~ "Leaderboard"
      assert html_comp =~ ~s(/learn/courses/#{comp_course.id}/leaderboard)

      std_course = insert(:course, title: "Standard Elixir", type: :standard)
      insert(:enrollment, account_id: user.id, course_id: std_course.id)

      {:ok, _lv_std, html_std} = live(conn, ~p"/learn/courses/#{std_course.id}")

      refute html_std =~ "Leaderboard"
    end
  end
end
