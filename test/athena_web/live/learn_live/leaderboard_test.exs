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
        score: 888,
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

      refute html =~ "888"
    end

    test "redirects if the course is not a competition", %{conn: conn} do
      other_course = insert(:course, type: :standard)

      {:error, {:live_redirect, %{to: "/learn", flash: flash}}} =
        live(conn, ~p"/learn/courses/#{other_course.id}/leaderboard")

      assert flash["error"] == "Access denied."
    end

    test "redirects if the competition is not published", %{conn: conn} do
      draft_competition = insert(:course, type: :competition, status: :draft)

      {:error, {:live_redirect, %{to: "/learn", flash: flash}}} =
        live(conn, ~p"/learn/courses/#{draft_competition.id}/leaderboard")

      assert flash["error"] == "Access denied."
    end

    test "any signed-in student can view a published competition's leaderboard, even without enrolling",
         %{conn: conn} do
      bystander = insert(:account)
      bystander_conn = init_test_session(conn, %{"account_id" => bystander.id})

      competition = insert(:course, type: :competition, status: :published)
      team = insert(:cohort, name: "Underdogs", type: :team)
      insert(:enrollment, course_id: competition.id, cohort_id: team.id)

      {:ok, _lv, html} = live(bystander_conn, ~p"/learn/courses/#{competition.id}/leaderboard")

      assert html =~ "Underdogs"
    end
  end

  describe "Team roster" do
    test "clicking a team shows its members, linking to their profiles", %{
      conn: conn,
      course: course
    } do
      member = insert(:account, login: "member_one")
      insert(:profile, owner: member, first_name: "Ada", last_name: "Lovelace")

      team = insert(:cohort, name: "The Hackers", type: :team)
      insert(:enrollment, course_id: course.id, cohort_id: team.id)
      insert(:cohort_membership, account_id: member.id, cohort_id: team.id)

      {:ok, lv, _html} = live(conn, ~p"/learn/courses/#{course.id}/leaderboard")

      html =
        lv
        |> element("tr[phx-value-team_id='#{team.id}']")
        |> render_click()

      assert html =~ "The Hackers"
      assert html =~ "Lovelace Ada"
      assert has_element?(lv, ~s{a[href="/profile/#{member.id}"]})
    end

    test "closes the team roster modal", %{conn: conn, course: course} do
      team = insert(:cohort, name: "Closers", type: :team)
      insert(:enrollment, course_id: course.id, cohort_id: team.id)

      {:ok, lv, _html} = live(conn, ~p"/learn/courses/#{course.id}/leaderboard")

      lv |> element("tr[phx-value-team_id='#{team.id}']") |> render_click()
      assert has_element?(lv, "#team-roster-modal.modal-open")

      html = lv |> element("#team-roster-modal .modal-backdrop") |> render_click()
      refute html =~ "modal-open"
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
