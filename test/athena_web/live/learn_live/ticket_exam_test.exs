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

    case Process.whereis(Athena.PG) do
      nil -> :pg.start_link(Athena.PG)
      _pid -> :ok
    end

    :pg.join(Athena.PG, :code_runners, self())

    on_exit(fn ->
      :pg.leave(Athena.PG, :code_runners, self())
    end)

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
end
