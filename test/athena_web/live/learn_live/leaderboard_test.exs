defmodule AthenaWeb.LearnLive.LeaderboardTest do
  use AthenaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  import Athena.Factory

  setup %{conn: conn} do
    user = insert(:account)
    course = insert(:course, title: "Cyber Olympiad 2026", type: :competition)

    insert(:enrollment, account_id: user.id, course_id: course.id)

    conn = init_test_session(conn, %{"account_id" => user.id})
    %{conn: conn, user: user, course: course}
  end

  describe "Leaderboard rendering" do
    test "renders empty state when no submissions exist", %{conn: conn, course: course} do
      {:ok, _lv, html} = live(conn, ~p"/learn/courses/#{course.id}/leaderboard")

      assert html =~ "Cyber Olympiad 2026"
      assert html =~ "Leaderboard"
      assert html =~ "This leaderboard is currently empty"
    end

    test "renders ranked teams and their scores", %{conn: conn, course: course} do
      team1 = insert(:cohort, name: "The Hackers", type: :team)
      team2 = insert(:cohort, name: "Script Kiddies", type: :team)

      insert(:enrollment, course_id: course.id, cohort_id: team1.id)
      insert(:enrollment, course_id: course.id, cohort_id: team2.id)

      section = insert(:section, course: course)
      block = insert(:block, section: section)

      insert(:submission, block_id: block.id, cohort_id: team1.id, score: 100, status: :graded)
      insert(:submission, block_id: block.id, cohort_id: team2.id, score: 50, status: :graded)

      {:ok, _lv, html} = live(conn, ~p"/learn/courses/#{course.id}/leaderboard")

      assert html =~ "The Hackers"
      assert html =~ "100"
      assert html =~ "Script Kiddies"
      assert html =~ "50"
    end

    test "calculates score using the best submission per block", %{conn: conn, course: course} do
      team = insert(:cohort, name: "Tryhards", type: :team)
      insert(:enrollment, course_id: course.id, cohort_id: team.id)

      section = insert(:section, course: course)
      block = insert(:block, section: section)

      insert(:submission,
        block_id: block.id,
        cohort_id: team.id,
        score: 50,
        status: :graded,
        inserted_at: ~U[2026-04-01 10:00:00Z]
      )

      insert(:submission,
        block_id: block.id,
        cohort_id: team.id,
        score: 100,
        status: :graded,
        inserted_at: ~U[2026-04-01 11:00:00Z]
      )

      insert(:submission,
        block_id: block.id,
        cohort_id: team.id,
        score: 0,
        status: :graded,
        inserted_at: ~U[2026-04-01 12:00:00Z]
      )

      {:ok, _lv, html} = live(conn, ~p"/learn/courses/#{course.id}/leaderboard")

      assert html =~ "Tryhards"
      assert html =~ "100"
    end

    test "renders disqualified state for teams with a rejected submission", %{
      conn: conn,
      course: course
    } do
      cheaters = insert(:cohort, name: "Team Rocket", type: :team)
      insert(:enrollment, course_id: course.id, cohort_id: cheaters.id)

      section = insert(:section, course: course)
      block1 = insert(:block, section: section)
      block2 = insert(:block, section: section)

      insert(:submission,
        block_id: block1.id,
        cohort_id: cheaters.id,
        score: 999,
        status: :graded
      )

      insert(:submission,
        block_id: block2.id,
        cohort_id: cheaters.id,
        score: 0,
        status: :rejected
      )

      {:ok, _lv, html} = live(conn, ~p"/learn/courses/#{course.id}/leaderboard")

      assert html =~ "Team Rocket"
      assert html =~ "Disqualified"
      assert html =~ "opacity-50 grayscale bg-error/5"

      refute html =~ "999"
    end

    test "redirects if user has no access to the course", %{conn: conn} do
      other_course = insert(:course)

      {:error, {:live_redirect, %{to: "/learn", flash: flash}}} =
        live(conn, ~p"/learn/courses/#{other_course.id}/leaderboard")

      assert flash["error"] == "Access denied."
    end
  end

  describe "Real-time updates" do
    test "updates leaderboard when a PubSub message is received", %{conn: conn, course: course} do
      team = insert(:cohort, name: "Late Bloomers", type: :team)
      insert(:enrollment, course_id: course.id, cohort_id: team.id)

      section = insert(:section, course: course)
      block = insert(:block, section: section)

      {:ok, lv, html} = live(conn, ~p"/learn/courses/#{course.id}/leaderboard")

      assert html =~ "Late Bloomers"
      refute html =~ "1337"

      insert(:submission, block_id: block.id, cohort_id: team.id, score: 1337, status: :graded)

      send(lv.pid, :update_leaderboard)

      updated_html = render(lv)

      assert updated_html =~ "Late Bloomers"
      assert updated_html =~ "1337"
    end
  end
end
