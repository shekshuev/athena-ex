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

      section = insert(:section, course: course)
      block = insert(:block, section: section)

      insert(:submission, block_id: block.id, cohort_id: team1.id, score: 100, status: :graded)
      insert(:submission, block_id: block.id, cohort_id: team2.id, score: 50, status: :graded)

      {:ok, _lv, html} = live(conn, ~p"/learn/courses/#{course.id}/leaderboard")

      assert html =~ "The Hackers"
      assert html =~ "100"
      assert html =~ "Script Kiddies"
      assert html =~ "50"

      assert html =~ "hero-trophy-solid"
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
      section = insert(:section, course: course)
      block = insert(:block, section: section)

      {:ok, lv, html} = live(conn, ~p"/learn/courses/#{course.id}/leaderboard")
      assert html =~ "This leaderboard is currently empty"

      insert(:submission, block_id: block.id, cohort_id: team.id, score: 95, status: :graded)

      Phoenix.PubSub.broadcast(
        Athena.PubSub,
        "leaderboard:#{course.id}",
        :update_leaderboard
      )

      updated_html = render(lv)

      refute updated_html =~ "This leaderboard is currently empty"
      assert updated_html =~ "Late Bloomers"
      assert updated_html =~ "95"
    end
  end
end
