defmodule AthenaWeb.TeachingLive.GradingDetailTest do
  use AthenaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  import Athena.Factory
  alias Athena.Learning.Submission

  setup %{conn: conn} do
    role = insert(:role, permissions: ["grading.read", "grading.update", "cohorts.read"])
    admin = insert(:account, role: role)
    conn = init_test_session(conn, %{"account_id" => admin.id})
    %{conn: conn, admin: admin}
  end

  describe "Grading Detail (Single Question)" do
    test "renders exact_match read-only submission properly", %{conn: conn} do
      student = insert(:account, login: "hacker_boy")

      block =
        insert(:block,
          type: :quiz_question,
          content: %{
            "question_type" => "exact_match",
            "correct_answer" => "athena_flag",
            "body" => %{"text" => "Find the flag"}
          }
        )

      sub =
        insert(:submission,
          account_id: student.id,
          block_id: block.id,
          content: %{"text_answer" => "athena_flag"},
          score: 100,
          status: :needs_review
        )

      {:ok, _lv, html} = live(conn, ~p"/teaching/grading/#{sub.id}")

      assert html =~ "Submission from hacker_boy"

      assert html =~ "quiz question"
      assert html =~ "athena_flag"
      assert html =~ "Correct:"
      assert html =~ ~r/ disabled(?!:)/
    end

    test "renders open question (essay) properly", %{conn: conn} do
      student = insert(:account, login: "tolstoy")

      block =
        insert(:block,
          type: :quiz_question,
          content: %{
            "question_type" => "open",
            "body" => %{"text" => "Write an essay"}
          }
        )

      sub =
        insert(:submission,
          account_id: student.id,
          block_id: block.id,
          content: %{"text_answer" => "War and Peace. Volume 1."},
          status: :needs_review
        )

      {:ok, _lv, html} = live(conn, ~p"/teaching/grading/#{sub.id}")

      assert html =~ "Submission from tolstoy"
      assert html =~ "War and Peace. Volume 1."
      assert html =~ "<textarea"
      assert html =~ ~r/ disabled(?!:)/
      assert html =~ "Manual Review"
    end
  end

  describe "Grading Detail (Exam & Cheating)" do
    test "renders exam with questions, open review badges, and cheat violations", %{conn: conn} do
      student = insert(:account, login: "sneaky_student")

      q1 =
        insert(:block,
          type: :quiz_question,
          content: %{"question_type" => "open", "body" => %{"text" => "Question 1"}}
        )

      q2 =
        insert(:block,
          type: :quiz_question,
          content: %{
            "question_type" => "single",
            "options" => [%{"id" => "o1", "text" => "Opt 1"}]
          }
        )

      block = insert(:block, type: :quiz_exam)

      sub =
        insert(:submission,
          account_id: student.id,
          block_id: block.id,
          content: %{
            "cheat_count" => 2,
            "questions" => [
              %{"id" => q1.id, "type" => "quiz_question", "content" => q1.content},
              %{"id" => q2.id, "type" => "quiz_question", "content" => q2.content}
            ]
          },
          status: :needs_review
        )

      insert(:submission,
        account_id: student.id,
        block_id: q1.id,
        parent_submission_id: sub.id,
        content: %{"text_answer" => "I don't know"},
        status: :needs_review
      )

      insert(:submission,
        account_id: student.id,
        block_id: q2.id,
        parent_submission_id: sub.id,
        content: %{"selected_choices" => ["o1"]},
        status: :graded
      )

      {:ok, _lv, html} = live(conn, ~p"/teaching/grading/#{sub.id}")

      assert html =~ "sneaky_student"
      assert html =~ "quiz exam"
      assert html =~ "I don&#39;t know"
      assert html =~ "Cheating Detected"
      assert html =~ "triggered 2 violations"
      assert html =~ "Manual Review"
    end

    test "does not render cheat violations if count is 0", %{conn: conn} do
      student = insert(:account)
      block = insert(:block, type: :quiz_exam)

      sub =
        insert(:submission,
          account_id: student.id,
          block_id: block.id,
          content: %{"cheat_count" => 0, "questions" => [], "answers" => %{}},
          status: :needs_review
        )

      {:ok, _lv, html} = live(conn, ~p"/teaching/grading/#{sub.id}")

      refute html =~ "Cheating Detected"
    end

    test "recalculates overall score when a child question score is changed", %{
      conn: conn
    } do
      course = insert(:course)
      student = insert(:account, login: "student_math")
      s1 = insert(:section, course: course)

      q1 =
        insert(:block, section: s1, type: :quiz_question, content: %{"question_type" => "open"})

      q2 =
        insert(:block, section: s1, type: :quiz_question, content: %{"question_type" => "open"})

      questions = [
        %{"id" => q1.id, "type" => "quiz_question", "content" => q1.content},
        %{"id" => q2.id, "type" => "quiz_question", "content" => q2.content}
      ]

      parent_block = insert(:block, section: s1, type: :quiz_exam)

      parent_sub =
        insert(:submission,
          account_id: student.id,
          block_id: parent_block.id,
          status: :needs_review,
          score: 0,
          content: %{"questions" => questions}
        )

      insert(:submission,
        account_id: student.id,
        block_id: q1.id,
        parent_submission_id: parent_sub.id,
        status: :needs_review,
        score: 0
      )

      insert(:submission,
        account_id: student.id,
        block_id: q2.id,
        parent_submission_id: parent_sub.id,
        status: :needs_review,
        score: 0
      )

      {:ok, lv, _html} = live(conn, ~p"/teaching/grading/#{parent_sub.id}")

      html =
        lv
        |> form("#grading-form")
        |> render_change(%{"child_grades" => %{q1.id => %{"score" => "100", "feedback" => ""}}})

      assert html =~ "value=\"50\""
    end
  end

  describe "Grading Action" do
    test "saves grade, updates feedback, sets status to graded, and redirects", %{conn: conn} do
      student = insert(:account)
      block = insert(:block, type: :quiz_question, content: %{"question_type" => "open"})

      sub =
        insert(:submission,
          account_id: student.id,
          block_id: block.id,
          score: 0,
          status: :needs_review
        )

      {:ok, lv, _html} = live(conn, ~p"/teaching/grading/#{sub.id}")

      lv
      |> form("#grading-form", %{"score" => "85", "feedback" => "Good essay, bro!"})
      |> render_submit(%{"action" => "grade"})
      |> follow_redirect(conn, ~p"/teaching/grading")

      updated_sub = Athena.Repo.get!(Submission, sub.id)

      assert updated_sub.score == 85
      assert updated_sub.feedback == "Good essay, bro!"
      assert updated_sub.status == :graded
    end

    test "reject action saves feedback, sets score to 0, status to rejected, and redirects", %{
      conn: conn
    } do
      student = insert(:account)
      block = insert(:block, type: :quiz_question, content: %{"question_type" => "open"})

      sub =
        insert(:submission,
          account_id: student.id,
          block_id: block.id,
          score: 0,
          status: :needs_review
        )

      {:ok, lv, _html} = live(conn, ~p"/teaching/grading/#{sub.id}")

      lv
      |> form("#grading-form", %{"score" => "85", "feedback" => "Very bad!"})
      |> render_submit(%{"action" => "reject"})

      assert_redirect(lv, "/teaching/grading")

      updated_sub = Athena.Repo.get!(Athena.Learning.Submission, sub.id)
      assert updated_sub.status == :rejected
      assert updated_sub.score == 0
      assert updated_sub.feedback == "Very bad!"
    end
  end

  describe "Permissions & ACL" do
    test "redirects if user lacks grading.update permission", %{conn: conn} do
      role = insert(:role, permissions: [])
      limited_user = insert(:account, role: role)
      conn = init_test_session(conn, %{"account_id" => limited_user.id})

      student = insert(:account)
      block = insert(:block)
      sub = insert(:submission, account_id: student.id, block_id: block.id)

      assert {:error, redirect} = live(conn, ~p"/teaching/grading/#{sub.id}")

      case redirect do
        {:redirect, %{to: _path}} -> assert true
        {:live_redirect, %{to: _path}} -> assert true
        _ -> flunk("Expected a redirect due to lack of permissions")
      end
    end
  end

  describe "Deleting Submissions (Rollback)" do
    test "renders the Delete & Rollback button and opens modal", %{conn: conn} do
      student = insert(:account)
      block = insert(:block, type: :quiz_question, content: %{"question_type" => "open"})
      sub = insert(:submission, account_id: student.id, block_id: block.id)

      {:ok, lv, html} = live(conn, ~p"/teaching/grading/#{sub.id}")

      assert html =~ "Delete Submission"
      assert html =~ "open_delete_modal"

      html =
        lv
        |> element("button[phx-click='open_delete_modal']")
        |> render_click()

      assert html =~ "Delete Submission"

      assert html =~
               "Are you sure? This will delete the submission and may lock the next lesson part for the student."
    end

    test "deletes individual submission, broadcasts to user, and redirects", %{
      conn: conn,
      admin: admin
    } do
      student = insert(:account)
      block = insert(:block, type: :quiz_question, content: %{"question_type" => "open"})

      sub = insert(:submission, account_id: student.id, block_id: block.id, cohort_id: nil)

      Phoenix.PubSub.subscribe(Athena.PubSub, "user_progress:#{student.id}")

      {:ok, lv, _html} = live(conn, ~p"/teaching/grading/#{sub.id}")

      lv
      |> element("button[phx-click='open_delete_modal']")
      |> render_click()

      render_hook(lv, "confirm_delete_submission")

      assert_redirect(lv, "/teaching/grading")

      assert_receive :user_progress_updated

      assert_raise Ecto.NoResultsError, fn ->
        Athena.Learning.Submissions.get_submission!(admin, sub.id)
      end
    end

    test "deletes team submission, broadcasts to team, and redirects", %{
      conn: conn,
      admin: admin
    } do
      student = insert(:account)
      team = insert(:cohort, type: :team)
      block = insert(:block, type: :quiz_question, content: %{"question_type" => "open"})

      sub = insert(:submission, account_id: student.id, block_id: block.id, cohort_id: team.id)

      Phoenix.PubSub.subscribe(Athena.PubSub, "team_progress:#{team.id}")

      {:ok, lv, _html} = live(conn, ~p"/teaching/grading/#{sub.id}")

      lv
      |> element("button[phx-click='open_delete_modal']")
      |> render_click()

      render_hook(lv, "confirm_delete_submission")

      assert_redirect(lv, "/teaching/grading")
      assert_receive :team_progress_updated

      assert_raise Ecto.NoResultsError, fn ->
        Athena.Learning.Submissions.get_submission!(admin, sub.id)
      end
    end
  end
end
