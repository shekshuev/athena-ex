defmodule AthenaWeb.DashboardLive.IndexTest do
  use AthenaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  import Athena.Factory
  alias Athena.Learning.Progress

  describe "Dashboard" do
    test "shows an empty state when the account has no enrollments", %{conn: conn} do
      account = insert(:account)
      conn = init_test_session(conn, %{"account_id" => account.id})

      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      assert html =~ "No courses yet"
    end

    test "shows enrolled courses with computed progress", %{conn: conn} do
      account = insert(:account)
      course = insert(:course)
      section = insert(:section, course: course)
      block1 = insert(:block, section: section)
      insert(:block, section: section)

      insert(:enrollment, account_id: account.id, course_id: course.id)
      Progress.mark_completed(account.id, block1.id)

      conn = init_test_session(conn, %{"account_id" => account.id})
      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      assert html =~ course.title
      assert html =~ "50%"
    end

    test "shows the continue-learning shortcut pointing at the last active section", %{
      conn: conn
    } do
      account = insert(:account)
      course = insert(:course)
      section = insert(:section, course: course)
      block = insert(:block, section: section)

      insert(:enrollment, account_id: account.id, course_id: course.id)
      Progress.mark_completed(account.id, block.id)

      conn = init_test_session(conn, %{"account_id" => account.id})
      {:ok, lv, html} = live(conn, ~p"/dashboard")

      assert html =~ "Continue learning"
      assert has_element?(lv, ~s{a[href="/learn/courses/#{course.id}/play/#{section.id}"]})
    end

    test "shows upcoming deadlines for the account's cohorts", %{conn: conn} do
      account = insert(:account)
      cohort = insert(:cohort)
      insert(:cohort_membership, account_id: account.id, cohort_id: cohort.id)

      course = insert(:course)
      section = insert(:section, course: course)

      future = DateTime.add(DateTime.utc_now(), 3600, :second) |> DateTime.truncate(:second)

      insert(:cohort_schedule,
        cohort_id: cohort.id,
        course_id: course.id,
        resource_type: :section,
        resource_id: section.id,
        lock_at: future
      )

      conn = init_test_session(conn, %{"account_id" => account.id})
      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      assert html =~ "Coming Up"
      assert html =~ course.title
      assert html =~ section.title
    end

    test "shows the pending-review widget for instructors with grading.read permission", %{
      conn: conn
    } do
      role = insert(:role, permissions: ["grading.read", "cohorts.read"])
      account = insert(:account, role: role)
      insert(:instructor, owner_id: account.id)
      insert(:submission, status: :needs_review)

      conn = init_test_session(conn, %{"account_id" => account.id})
      {:ok, lv, html} = live(conn, ~p"/dashboard")

      assert has_element?(lv, "h2", "Teaching")
      assert html =~ "awaiting review"
      assert html =~ "Go to grading"
    end

    test "hides the pending-review widget for accounts without grading.read permission", %{
      conn: conn
    } do
      role = insert(:role, permissions: ["cohorts.read"])
      account = insert(:account, role: role)
      insert(:instructor, owner_id: account.id)
      insert(:submission, status: :needs_review)

      conn = init_test_session(conn, %{"account_id" => account.id})
      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      refute html =~ "awaiting review"
    end

    test "hides the whole Teaching section for accounts without an instructor profile, even with grading.read",
         %{conn: conn} do
      role = insert(:role, permissions: ["grading.read", "cohorts.read"])
      account = insert(:account, role: role)
      insert(:submission, status: :needs_review)

      conn = init_test_session(conn, %{"account_id" => account.id})
      {:ok, lv, _html} = live(conn, ~p"/dashboard")

      refute has_element?(lv, "h2", "Teaching")
      refute has_element?(lv, "a", "Go to grading")
    end

    test "shows quiet cohort members to an instructor managing the cohort", %{conn: conn} do
      role = insert(:role, permissions: ["cohorts.read"])
      account = insert(:account, role: role)
      instructor = insert(:instructor, owner_id: account.id)

      cohort = insert(:cohort, type: :academic)
      insert(:cohort_instructor, cohort_id: cohort.id, instructor_id: instructor.id)

      quiet_student = insert(:account)
      insert(:cohort_membership, account_id: quiet_student.id, cohort_id: cohort.id)

      conn = init_test_session(conn, %{"account_id" => account.id})
      {:ok, lv, html} = live(conn, ~p"/dashboard")

      assert has_element?(lv, "h2", "Teaching")
      assert html =~ cohort.name
      assert html =~ "Quiet this week"
      assert html =~ quiet_student.login
    end

    test "shows a daily challenge once an eligible block has been solved", %{conn: conn} do
      account = insert(:account)
      course = insert(:course)
      section = insert(:section, course: course)
      block = insert(:block, section: section, type: :code)

      insert(:enrollment, account_id: account.id, course_id: course.id)
      Progress.mark_completed(account.id, block.id)

      conn = init_test_session(conn, %{"account_id" => account.id})
      {:ok, lv, html} = live(conn, ~p"/dashboard")

      assert html =~ "Daily challenge"
      assert html =~ course.title
      assert has_element?(lv, "a", "Solve")
    end

    test "does not show a daily challenge widget without any eligible completed block", %{
      conn: conn
    } do
      account = insert(:account)
      conn = init_test_session(conn, %{"account_id" => account.id})

      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      refute html =~ "Daily challenge"
    end

    test "shows the account's XP/level badge linking to achievements", %{conn: conn} do
      account = insert(:account)
      block = insert(:block, type: :code)

      Athena.Gamification.XpLedger.record_activity(%{
        account_id: account.id,
        block_id: block.id,
        block_type: :code
      })

      conn = init_test_session(conn, %{"account_id" => account.id})
      {:ok, lv, html} = live(conn, ~p"/dashboard")

      assert html =~ "Level 1"
      assert html =~ "15 XP"
      assert has_element?(lv, ~s{a[href="/me?tab=achievements"]})
    end
  end
end
