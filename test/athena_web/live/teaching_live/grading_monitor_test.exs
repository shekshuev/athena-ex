defmodule AthenaWeb.TeachingLive.GradingMonitorTest do
  use AthenaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  import Athena.Factory

  setup %{conn: conn} do
    role = insert(:role, permissions: ["grading.read", "grading.update", "cohorts.read"])
    admin = insert(:account, role: role)
    conn = init_test_session(conn, %{"account_id" => admin.id})
    %{conn: conn, admin: admin}
  end

  describe "Grading Monitor" do
    test "shows every academic-group member's live risk status for the clicked block", %{
      conn: conn
    } do
      course = insert(:course)
      section = insert(:section, course: course)
      block = insert(:block, section: section, type: :quiz_exam)
      cohort = insert(:cohort, name: "Section A")
      insert(:enrollment, cohort_id: cohort.id, course_id: course.id, status: :active)

      flagged = insert(:account, login: "alice_flagged")
      clean = insert(:account, login: "carol_clean")
      not_started = insert(:account, login: "bob_notstarted")

      for account <- [flagged, clean, not_started] do
        insert(:cohort_membership, cohort_id: cohort.id, account_id: account.id)
      end

      flagged_sub =
        insert(:submission,
          account_id: flagged.id,
          block_id: block.id,
          content: %{
            "hard_evidence_count" => 2,
            "outlier_metrics" => %{},
            "risk_level" => "red"
          },
          status: :needs_review
        )

      insert(:submission,
        account_id: clean.id,
        block_id: block.id,
        content: %{
          "hard_evidence_count" => 0,
          "outlier_metrics" => %{},
          "risk_level" => "green"
        },
        status: :needs_review
      )

      {:ok, _lv, html} = live(conn, ~p"/teaching/grading/#{flagged_sub.id}/monitor")

      assert html =~ "Cheating Monitor"
      assert html =~ "Section A"
      assert html =~ "How this is measured"

      assert html =~ "alice_flagged"
      assert html =~ "High risk"

      assert html =~ "carol_clean"
      assert html =~ "No violations"

      assert html =~ "bob_notstarted"
      assert html =~ "Not started"
    end

    test "shows a live badge the moment a student starts, without waiting for a cheat event", %{
      conn: conn
    } do
      course = insert(:course)
      section = insert(:section, course: course)
      block = insert(:block, section: section, type: :quiz_exam, content: %{"count" => 1})
      cohort = insert(:cohort, name: "Section A")
      insert(:enrollment, cohort_id: cohort.id, course_id: course.id, status: :active)

      already_started = insert(:account, login: "already_started")
      late_starter = insert(:account, login: "late_starter")

      for account <- [already_started, late_starter] do
        insert(:cohort_membership, cohort_id: cohort.id, account_id: account.id)
      end

      seed_sub =
        insert(:submission, account_id: already_started.id, block_id: block.id, status: :pending)

      {:ok, lv, html} = live(conn, ~p"/teaching/grading/#{seed_sub.id}/monitor")
      assert html =~ "late_starter"
      assert html =~ "Not started"

      {:ok, _sub} =
        Athena.Learning.get_or_create_exam_attempt(
          course.id,
          late_starter.id,
          block.id,
          :quiz_exam,
          cohort.id,
          3600,
          block.content
        )

      html = render(lv)
      refute html =~ "Not started"
      assert html =~ "No violations"
    end

    test "redirects with a flash when the submission's academic group can't be resolved", %{
      conn: conn
    } do
      block = insert(:block, type: :quiz_exam)
      sub = insert(:submission, block_id: block.id, status: :needs_review)

      assert {:error, {:live_redirect, %{to: "/teaching/grading"}}} =
               live(conn, ~p"/teaching/grading/#{sub.id}/monitor")
    end
  end
end
