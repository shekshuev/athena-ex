defmodule AthenaWeb.LearnLive.TicketExamTest do
  use AthenaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Athena.Factory

  setup %{conn: conn} do
    user = insert(:account)
    conn = init_test_session(conn, %{"account_id" => user.id})

    course = insert(:course)
    insert(:enrollment, account_id: user.id, course_id: course.id)
    section = insert(:section, course: course)

    # `Execution.runner_available?/1` and `pick_runner/1` already find a
    # working runner without any of this: the test env's `server_role` is
    # "all" (config/test.exs), so `Athena.Execution.TaskSupervisor` starts
    # and registers itself for every language family at application boot,
    # for the whole suite's lifetime. Registering a second, test-scoped
    # runner here used to be actively harmful once a test let code execution
    # run for real: `:pg.get_members/2` returns members in no particular
    # order, so a *different*, concurrently-running test could randomly pick
    # this test's runner via `Enum.random/1` - and since that runner was
    # only ever meant to live as long as this one test, it (and any task
    # still running under it) died the moment this test exited.

    %{conn: conn, user: user, course: course, section: section}
  end

  defp generate_dummy_questions() do
    [
      %{
        "id" => Ecto.UUID.generate(),
        "type" => "quiz_question",
        "content" => %{"question_type" => "exact_match", "body" => %{"text" => "What is 2+2?"}}
      },
      %{
        "id" => Ecto.UUID.generate(),
        "type" => "quiz_question",
        "content" => %{
          "question_type" => "single",
          "body" => %{"text" => "Is water wet?"},
          "options" => [
            %{"id" => "opt1", "text" => "Yes", "is_correct" => true},
            %{"id" => "opt2", "text" => "No", "is_correct" => false}
          ]
        }
      },
      %{
        "id" => Ecto.UUID.generate(),
        "type" => "quiz_question",
        "content" => %{"question_type" => "open", "body" => %{"text" => "Write an essay."}}
      }
    ]
  end

  describe "Access & Mount" do
    test "mounts successfully with a pending submission and renders questions", %{
      conn: conn,
      course: course,
      section: section,
      user: user
    } do
      block =
        insert(:block,
          section: section,
          type: :ticket_exam,
          content: %{"slots" => [%{}, %{}, %{}]}
        )

      questions = generate_dummy_questions()

      insert(:submission,
        account_id: user.id,
        block_id: block.id,
        status: :pending,
        expires_at:
          DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second),
        content: %{
          "type" => "ticket_exam",
          "started_at" => DateTime.utc_now(),
          "questions" => questions
        }
      )

      {:ok, _lv, html} = live(conn, ~p"/learn/courses/#{course.id}/ticket/#{block.id}")

      assert html =~ "Ticket Assessment"
      assert html =~ "What is 2+2?"
      assert html =~ "Type your answer..."
      assert html =~ "Next"
    end
  end

  describe "Instructor terminates a live attempt" do
    test "rejecting from the grading screen ends the session immediately, without re-grading it",
         %{conn: conn, course: course, section: section, user: user} do
      block =
        insert(:block,
          section: section,
          type: :ticket_exam,
          content: %{"slots" => [%{}, %{}, %{}]}
        )

      questions = generate_dummy_questions()

      submission =
        insert(:submission,
          account_id: user.id,
          block_id: block.id,
          status: :pending,
          expires_at:
            DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second),
          content: %{
            "type" => "ticket_exam",
            "started_at" => DateTime.utc_now(),
            "questions" => questions
          }
        )

      {:ok, lv, _html} = live(conn, ~p"/learn/courses/#{course.id}/ticket/#{block.id}")

      teacher_role = insert(:role, permissions: ["grading.read", "grading.update"])
      teacher = insert(:account, role: teacher_role)

      {:ok, rejected} =
        Athena.Learning.update_submission(teacher, submission, %{
          "score" => "0",
          "feedback" => "Caught copying answers.",
          "status" => "rejected"
        })

      assert rejected.status == :rejected

      assert_redirect(lv, ~p"/learn/courses/#{course.id}/play")

      assert Athena.Repo.reload!(submission).feedback == "Caught copying answers."
    end
  end

  describe "Ticket Exam Navigation & Autosave" do
    setup %{conn: conn, course: course, section: section, user: user} do
      block =
        insert(:block,
          section: section,
          type: :ticket_exam,
          content: %{"slots" => [%{}, %{}, %{}]}
        )

      questions = generate_dummy_questions()
      q1_id = Enum.at(questions, 0)["id"]
      q2_id = Enum.at(questions, 1)["id"]
      q3_id = Enum.at(questions, 2)["id"]

      sub =
        insert(:submission,
          account_id: user.id,
          block_id: block.id,
          status: :pending,
          expires_at:
            DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second),
          content: %{
            "type" => "ticket_exam",
            "started_at" => DateTime.utc_now(),
            "questions" => questions
          }
        )

      {:ok, lv, _html} = live(conn, ~p"/learn/courses/#{course.id}/ticket/#{block.id}")

      %{lv: lv, block: block, sub: sub, q1_id: q1_id, q2_id: q2_id, q3_id: q3_id, user: user}
    end

    test "saves answer via child submission, highlights navigation, and navigates to next question",
         %{
           lv: lv,
           sub: sub,
           q1_id: q1_id,
           user: user
         } do
      lv
      |> form("#ticket-quiz-#{q1_id}", %{"answer" => "4"})
      |> render_change()

      child_sub =
        Athena.Repo.get_by!(Athena.Learning.Submission,
          parent_submission_id: sub.id,
          block_id: q1_id,
          account_id: user.id
        )

      assert child_sub.content["text_answer"] == "4"

      html =
        lv
        |> form("#ticket-quiz-#{q1_id}", %{"answer" => "4"})
        |> render_submit()

      assert html =~ "Is water wet?"
      assert html =~ "Yes"

      assert html =~ ~r/phx-value-index="0"[^>]*bg-success\/10/
    end

    test "jumps to specific question and renders finish button on last question when all answered",
         %{
           lv: lv,
           q1_id: q1_id,
           q2_id: q2_id,
           q3_id: q3_id
         } do
      lv |> form("#ticket-quiz-#{q1_id}", %{"answer" => "4"}) |> render_change()

      lv |> element("button[phx-click='jump_to'][phx-value-index='1']") |> render_click()
      lv |> form("#ticket-quiz-#{q2_id}", %{"answer" => "opt1"}) |> render_change()

      _html = render_click(lv, "jump_to", %{"index" => "2"})

      lv |> form("#ticket-quiz-#{q3_id}", %{"answer" => "My essay"}) |> render_change()

      html = render(lv)

      assert html =~ "Write an essay."
      assert html =~ "Finish &amp; Submit"
      refute html =~ "Next <span class=\"hero-arrow-right"
    end

    test "highlights current question in navigation", %{lv: lv} do
      html = render_click(lv, "jump_to", %{"index" => "1"})

      assert html =~ ~r/phx-value-index="1"[^>]*bg-primary text-primary-content/
    end
  end

  describe "Matching question in ticket exam" do
    test "saves matching answer via child submission and grades it correctly", %{
      conn: conn,
      course: course,
      section: section,
      user: user
    } do
      pair1_id = Ecto.UUID.generate()
      pair2_id = Ecto.UUID.generate()
      q_id = Ecto.UUID.generate()

      questions = [
        %{
          "id" => q_id,
          "type" => "quiz_question",
          "content" => %{
            "question_type" => "matching",
            "body" => %{"text" => "Match the terms"},
            "pairs" => [
              %{"id" => pair1_id, "left" => "Alpha", "right" => "One"},
              %{"id" => pair2_id, "left" => "Beta", "right" => "Two"}
            ]
          }
        }
      ]

      block =
        insert(:block, section: section, type: :ticket_exam, content: %{"slots" => [%{}]})

      sub =
        insert(:submission,
          account_id: user.id,
          block_id: block.id,
          status: :pending,
          expires_at:
            DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second),
          content: %{
            "type" => "ticket_exam",
            "started_at" => DateTime.utc_now(),
            "questions" => questions
          }
        )

      {:ok, lv, html} = live(conn, ~p"/learn/courses/#{course.id}/ticket/#{block.id}")

      assert html =~ "drag-handle"
      assert html =~ ~s(data-id="#{pair1_id}")

      # With exactly 2 pairs, the initial shuffle is guaranteed to start in the wrong
      # order (see initial_matching_order/3's anti-trivial-solve swap) — one drag
      # brings it to the correct order.
      render_hook(lv, "reorder_matching_answer", %{"old_index" => 0, "new_index" => 1})

      child_sub =
        Athena.Repo.get_by!(Athena.Learning.Submission,
          parent_submission_id: sub.id,
          block_id: q_id,
          account_id: user.id
        )

      assert child_sub.content["matches"] == [pair1_id, pair2_id]

      lv
      |> form("#ticket-quiz-#{q_id}", %{})
      |> render_submit()

      res =
        Athena.Learning.Evaluator.evaluate_sync(
          Athena.Repo.get!(Athena.Learning.Submission, sub.id)
        )

      assert res.score == 100
    end
  end

  describe "Ticket exam completion" do
    test "finishing a fully auto-graded ticket that passes the gate marks the block completed",
         %{
           conn: conn,
           course: course,
           section: section,
           user: user
         } do
      block =
        insert(:block,
          section: section,
          type: :ticket_exam,
          content: %{"slots" => [%{}, %{}]},
          completion_rule: %Athena.Content.CompletionRule{type: :pass_auto_grade, min_score: 60}
        )

      questions = [
        %{
          "id" => Ecto.UUID.generate(),
          "type" => "quiz_question",
          "content" => %{
            "question_type" => "exact_match",
            "body" => %{"text" => "What is 2+2?"},
            "correct_answer" => "4"
          }
        },
        %{
          "id" => Ecto.UUID.generate(),
          "type" => "quiz_question",
          "content" => %{
            "question_type" => "exact_match",
            "body" => %{"text" => "What is 3+3?"},
            "correct_answer" => "6"
          }
        }
      ]

      q1_id = Enum.at(questions, 0)["id"]
      q2_id = Enum.at(questions, 1)["id"]

      insert(:submission,
        account_id: user.id,
        block_id: block.id,
        status: :pending,
        expires_at:
          DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second),
        content: %{
          "type" => "ticket_exam",
          "started_at" => DateTime.utc_now(),
          "questions" => questions
        }
      )

      {:ok, lv, _html} = live(conn, ~p"/learn/courses/#{course.id}/ticket/#{block.id}")

      lv |> form("#ticket-quiz-#{q1_id}", %{"answer" => "4"}) |> render_submit()
      lv |> form("#ticket-quiz-#{q2_id}", %{"answer" => "6"}) |> render_submit()

      lv
      |> render_click("finish_exam", %{})

      assert Athena.Repo.get_by(Athena.Learning.BlockProgress,
               account_id: user.id,
               block_id: block.id,
               status: :completed
             )
    end

    test "finishing a fully auto-graded ticket that fails the gate does not complete the block",
         %{
           conn: conn,
           course: course,
           section: section,
           user: user
         } do
      block =
        insert(:block,
          section: section,
          type: :ticket_exam,
          content: %{"slots" => [%{}]},
          completion_rule: %Athena.Content.CompletionRule{type: :pass_auto_grade, min_score: 60}
        )

      questions = [
        %{
          "id" => Ecto.UUID.generate(),
          "type" => "quiz_question",
          "content" => %{
            "question_type" => "exact_match",
            "body" => %{"text" => "What is 2+2?"},
            "correct_answer" => "4"
          }
        }
      ]

      q1_id = Enum.at(questions, 0)["id"]

      insert(:submission,
        account_id: user.id,
        block_id: block.id,
        status: :pending,
        expires_at:
          DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second),
        content: %{
          "type" => "ticket_exam",
          "started_at" => DateTime.utc_now(),
          "questions" => questions
        }
      )

      {:ok, lv, _html} = live(conn, ~p"/learn/courses/#{course.id}/ticket/#{block.id}")

      lv |> form("#ticket-quiz-#{q1_id}", %{"answer" => "wrong"}) |> render_submit()

      lv
      |> render_click("finish_exam", %{})

      refute Athena.Repo.get_by(Athena.Learning.BlockProgress,
               account_id: user.id,
               block_id: block.id
             )
    end
  end
end
