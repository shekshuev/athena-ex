defmodule AthenaWeb.TeachingLive.GradingTest do
  use AthenaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  import Athena.Factory

  setup %{conn: conn} do
    role = insert(:role, permissions: ["grading.read", "cohorts.read"])
    admin = insert(:account, role: role)
    conn = init_test_session(conn, %{"account_id" => admin.id})
    %{conn: conn, admin: admin}
  end

  describe "Grading page (Index & Default Filters)" do
    test "should render all assignments by default (status 'all')", %{conn: conn} do
      student1 = insert(:account, login: "johndoe")
      student2 = insert(:account, login: "janedoe")
      block1 = insert(:block, type: :quiz_exam)
      block2 = insert(:block, type: :code)

      insert(:submission,
        account_id: student1.id,
        block_id: block1.id,
        status: :needs_review
      )

      insert(:submission,
        account_id: student2.id,
        block_id: block2.id,
        status: :graded,
        score: 100
      )

      {:ok, _lv, html} = live(conn, ~p"/teaching/grading")

      assert html =~ "Grading Center"

      assert html =~ "johndoe"
      assert html =~ "Needs review"
      # A preliminary score is still shown while the answer awaits review.
      assert html =~ "Preliminary score"

      assert html =~ "janedoe"
      assert html =~ "Graded"
      assert html =~ "100 <span class=\"text-xs opacity-50 font-normal\">/ 100</span>"
    end

    test "should handle unknown accounts or blocks gracefully", %{conn: conn} do
      insert(:submission,
        account_id: Ecto.UUID.generate(),
        block_id: Ecto.UUID.generate(),
        status: :needs_review
      )

      {:ok, _lv, html} = live(conn, ~p"/teaching/grading")

      assert html =~ "Unknown"
      assert html =~ "Deleted"
    end

    test "renders rejected submissions correctly", %{conn: conn} do
      student = insert(:account, login: "cheater_student")
      block = insert(:block)

      insert(:submission,
        account_id: student.id,
        block_id: block.id,
        status: :rejected,
        score: 0
      )

      {:ok, _lv, html} = live(conn, ~p"/teaching/grading")

      assert html =~ "cheater_student"
      assert html =~ "Rejected"
      assert html =~ "badge-error badge-soft"
      assert html =~ "text-error"
    end
  end

  describe "Grading page (Filtering)" do
    test "filters by status using the select dropdown", %{conn: conn} do
      student1 = insert(:account, login: "needs_review_student")
      student2 = insert(:account, login: "graded_student")
      block = insert(:block)

      insert(:submission, account_id: student1.id, block_id: block.id, status: :needs_review)
      insert(:submission, account_id: student2.id, block_id: block.id, status: :graded)

      {:ok, lv, _html} = live(conn, ~p"/teaching/grading")

      html =
        lv
        |> form("form[phx-change='update_filters']", %{"status" => "graded"})
        |> render_change()

      assert html =~ "graded_student"
      refute html =~ "needs_review_student"
    end

    test "filters by student login", %{conn: conn} do
      student1 = insert(:account, login: "alice_smith")
      student2 = insert(:account, login: "bob_jones")
      block = insert(:block)

      insert(:submission, account_id: student1.id, block_id: block.id)
      insert(:submission, account_id: student2.id, block_id: block.id)

      {:ok, lv, _html} = live(conn, ~p"/teaching/grading")

      html =
        lv |> form("form[phx-change='update_filters']", %{"login" => "alice"}) |> render_change()

      assert html =~ "alice_smith"
      refute html =~ "bob_jones"
    end

    test "filtering by a team shows the team's shared submissions", %{conn: conn} do
      team = insert(:cohort, name: "Red Team", type: :team)
      member = insert(:account, login: "team_member")
      solo = insert(:account, login: "solo_boy")
      insert(:cohort_membership, account_id: member.id, cohort_id: team.id)
      block = insert(:block)

      insert(:submission, account_id: member.id, block_id: block.id, cohort_id: team.id)
      insert(:submission, account_id: solo.id, block_id: block.id)

      {:ok, _lv, html} = live(conn, ~p"/teaching/grading?#{%{"cohort_id" => team.id}}")

      assert html =~ "team_member"
      refute html =~ "solo_boy"
    end

    test "filtering by a group shows its members' own submissions", %{conn: conn} do
      group = insert(:cohort, name: "Group 342", type: :academic)
      team = insert(:cohort, name: "Red Team", type: :team)
      member = insert(:account, login: "group_member")
      outsider = insert(:account, login: "outsider")
      insert(:cohort_membership, account_id: member.id, cohort_id: group.id)
      block = insert(:block)
      team_block = insert(:block)

      insert(:submission, account_id: member.id, block_id: block.id)
      insert(:submission, account_id: outsider.id, block_id: block.id)
      # The member's work for a team is the team's, not the group's.
      insert(:submission, account_id: member.id, block_id: team_block.id, cohort_id: team.id)

      # Exactly the link the engagement dashboard builds.
      {:ok, _lv, html} =
        live(conn, ~p"/teaching/grading?#{%{"block_id" => block.id, "cohort_id" => group.id}}")

      assert html =~ "group_member"
      refute html =~ "outsider"

      {:ok, _lv, html} = live(conn, ~p"/teaching/grading?#{%{"cohort_id" => group.id}}")
      assert html =~ "group_member"
      refute html =~ "Red Team"
      assert length(Regex.scan(~r/group_member/, html)) == 1
    end

    test "filters by date range", %{conn: conn} do
      student1 = insert(:account, login: "old_sub")
      student2 = insert(:account, login: "new_sub")
      block = insert(:block)

      insert(:submission,
        account_id: student1.id,
        block_id: block.id,
        inserted_at: ~U[2024-01-01 12:00:00Z]
      )

      insert(:submission,
        account_id: student2.id,
        block_id: block.id,
        inserted_at: ~U[2026-05-05 12:00:00Z]
      )

      {:ok, lv, _html} = live(conn, ~p"/teaching/grading")

      html =
        lv
        |> form("form[phx-change='update_filters']")
        |> render_change(%{"date_from" => "2026-05-01", "date_to" => "2026-05-10"})

      assert html =~ "new_sub"
      refute html =~ "old_sub"
    end

    test "reset filters clears all params and redirects back to base url", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/teaching/grading?status=graded&login=foo")

      lv |> element("#grading-active-filters button[phx-click='reset_filters']") |> render_click()

      assert_patch(lv, "/teaching/grading")
    end

    test "each active filter shows as a chip and clears on its own", %{conn: conn} do
      cohort = insert(:cohort, name: "Group 342", type: :academic)
      member = insert(:account, login: "graded_member")
      insert(:cohort_membership, account_id: member.id, cohort_id: cohort.id)
      block = insert(:block)
      insert(:submission, account_id: member.id, block_id: block.id, status: :graded)

      {:ok, lv, _html} =
        live(
          conn,
          ~p"/teaching/grading?#{%{"status" => "needs_review", "cohort_id" => cohort.id}}"
        )

      assert lv |> element("#grading-active-filters-status") |> render() =~ "Needs Review"
      assert lv |> element("#grading-active-filters-cohort_id") |> render() =~ "Group 342"
      refute render(lv) =~ "graded_member"

      lv |> element("#grading-active-filters-status button") |> render_click()

      # Status is gone, the group filter stays.
      refute has_element?(lv, "#grading-active-filters-status")
      assert has_element?(lv, "#grading-active-filters-cohort_id")
      assert render(lv) =~ "graded_member"
    end

    test "with no filters there are no chips", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/teaching/grading")
      refute has_element?(lv, "#grading-active-filters")
    end

    test "filters by rejected status using the select dropdown", %{conn: conn} do
      student1 = insert(:account, login: "good_boy")
      student2 = insert(:account, login: "bad_boy")
      block = insert(:block)

      insert(:submission, account_id: student1.id, block_id: block.id, status: :graded)
      insert(:submission, account_id: student2.id, block_id: block.id, status: :rejected)

      {:ok, lv, _html} = live(conn, ~p"/teaching/grading")

      html =
        lv
        |> form("form[phx-change='update_filters']", %{"status" => "rejected"})
        |> render_change()

      assert html =~ "bad_boy"
      refute html =~ "good_boy"
    end

    test "filters by block_id via url param, shown as a clearable chip", %{conn: conn} do
      student1 = insert(:account, login: "block1_boy")
      student2 = insert(:account, login: "block2_boy")
      block1 = insert(:block, type: :text)
      block2 = insert(:block, type: :code)

      insert(:submission, account_id: student1.id, block_id: block1.id)
      insert(:submission, account_id: student2.id, block_id: block2.id)

      {:ok, lv, html} = live(conn, ~p"/teaching/grading?block_id=#{block1.id}")

      assert html =~ "block1_boy"
      refute html =~ "block2_boy"

      assert has_element?(lv, "#grading-active-filters-block_id")

      html = lv |> element("#grading-active-filters-block_id button") |> render_click()
      assert html =~ "block2_boy"
    end

    test "filters by block_id for ticket_exam and displays correct label", %{conn: conn} do
      student = insert(:account, login: "ticket_boy")
      block = insert(:block, type: :ticket_exam)
      insert(:submission, account_id: student.id, block_id: block.id)

      {:ok, lv, html} = live(conn, ~p"/teaching/grading?block_id=#{block.id}")

      assert html =~ "ticket_boy"
      assert lv |> element("#grading-active-filters-block_id") |> render() =~ "Ticket Assessment"
      assert html =~ "Ticket Assessment"
    end
  end

  describe "Grading page (Pagination & Sorting)" do
    test "changes page size and updates URL", %{conn: conn} do
      insert(:submission, account_id: insert(:account).id, block_id: insert(:block).id)
      {:ok, lv, _html} = live(conn, ~p"/teaching/grading")

      lv
      |> form("form[phx-change='update_page_size']", %{"page_size" => "10"})
      |> render_change()

      assert_patched(
        lv,
        ~p"/teaching/grading?order_by[]=inserted_at&order_directions[]=desc&page=1&page_size=10"
      )
    end

    test "sorts by score when column header is clicked", %{conn: conn} do
      insert(:submission, account_id: insert(:account).id, block_id: insert(:block).id, score: 90)

      {:ok, lv, _html} = live(conn, ~p"/teaching/grading")

      lv
      |> element("a", "Score")
      |> render_click()

      assert_patched(
        lv,
        ~p"/teaching/grading?order_by[]=score&order_directions[]=asc&page=1&page_size=10"
      )
    end
  end

  describe "Grading page (Test-run submissions)" do
    test "excludes submissions made by an instructor's test-run session", %{conn: conn} do
      real_student = insert(:account, login: "real_student")
      test_run_account = insert(:account, login: "__test_run_ghost")
      block = insert(:block)

      insert(:submission, account_id: real_student.id, block_id: block.id, status: :needs_review)

      insert(:submission,
        account_id: test_run_account.id,
        block_id: block.id,
        status: :needs_review
      )

      insert(:test_run_session, ephemeral_account_id: test_run_account.id)

      {:ok, _lv, html} = live(conn, ~p"/teaching/grading")

      assert html =~ "real_student"
      refute html =~ "__test_run_ghost"
    end
  end

  describe "Grading page (Delete submission)" do
    setup %{conn: conn} do
      role = insert(:role, permissions: ["grading.read", "grading.update"])
      grader = insert(:account, role: role)
      conn = init_test_session(conn, %{"account_id" => grader.id})
      %{conn: conn, grader: grader}
    end

    test "deletes a submission after confirming the modal", %{conn: conn} do
      student = insert(:account, login: "to_be_forgotten")
      block = insert(:block)

      submission =
        insert(:submission, account_id: student.id, block_id: block.id, status: :needs_review)

      {:ok, lv, html} = live(conn, ~p"/teaching/grading")
      assert html =~ "to_be_forgotten"
      refute html =~ "delete-submission-modal"

      html =
        lv
        |> element("button[phx-click='open_delete_modal'][phx-value-id='#{submission.id}']")
        |> render_click()

      assert html =~ "delete-submission-modal"
      assert html =~ "Delete &amp; Rollback"

      html =
        lv
        |> element("#delete-submission-modal button", "Delete & Rollback")
        |> render_click()

      refute html =~ "to_be_forgotten"
      refute Athena.Repo.get(Athena.Learning.Submission, submission.id)
    end

    test "closing the modal without confirming keeps the submission", %{conn: conn} do
      student = insert(:account, login: "still_here")
      block = insert(:block)
      submission = insert(:submission, account_id: student.id, block_id: block.id)

      {:ok, lv, _html} = live(conn, ~p"/teaching/grading")

      lv
      |> element("button[phx-click='open_delete_modal'][phx-value-id='#{submission.id}']")
      |> render_click()

      html = lv |> element("#delete-submission-modal button", "Cancel") |> render_click()

      assert html =~ "still_here"
      assert Athena.Repo.get(Athena.Learning.Submission, submission.id)
    end
  end

  describe "Permissions & ACL" do
    test "should redirect if user lacks grading.read permission", %{conn: conn} do
      role = insert(:role, permissions: [])
      limited_user = insert(:account, role: role)
      conn = init_test_session(conn, %{"account_id" => limited_user.id})

      assert {:error, redirect} = live(conn, ~p"/teaching/grading")

      case redirect do
        {:redirect, %{to: _path}} -> assert true
        {:live_redirect, %{to: _path}} -> assert true
        _ -> flunk("Expected a redirect due to lack of permissions")
      end
    end
  end
end
