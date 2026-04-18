defmodule AthenaWeb.LearnLive.ExamTest do
  use AthenaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  import Athena.Factory

  setup %{conn: conn} do
    user = insert(:account)
    conn = init_test_session(conn, %{"account_id" => user.id})

    course = insert(:course)
    insert(:enrollment, account_id: user.id, course_id: course.id)

    section = insert(:section, course: course)

    %{conn: conn, user: user, course: course, section: section}
  end

  defp generate_dummy_questions() do
    [
      %{
        "id" => Ecto.UUID.generate(),
        "type" => "exact_match",
        "question" => %{"text" => "What is 2+2?"}
      },
      %{
        "id" => Ecto.UUID.generate(),
        "type" => "single",
        "question" => %{"text" => "Is water wet?"},
        "options" => [
          %{"id" => "opt1", "text" => "Yes"},
          %{"id" => "opt2", "text" => "No"}
        ]
      },
      %{
        "id" => Ecto.UUID.generate(),
        "type" => "open",
        "question" => %{"text" => "Write an essay."}
      }
    ]
  end

  describe "Access & Mount" do
    test "redirects to course if no pending submission exists", %{
      conn: conn,
      course: course,
      section: section
    } do
      block = insert(:block, section: section, type: :quiz_exam, content: %{"count" => 10})

      {:error, {:live_redirect, %{to: redirect_path, flash: flash}}} =
        live(conn, ~p"/learn/courses/#{course.id}/exam/#{block.id}")

      assert redirect_path == "/learn/courses/#{course.id}"
      assert flash["error"] == "Exam is not active or already finished."
    end

    test "mounts successfully with a pending submission and renders questions", %{
      conn: conn,
      course: course,
      section: section,
      user: user
    } do
      block = insert(:block, section: section, type: :quiz_exam, content: %{"count" => 3})
      questions = generate_dummy_questions()

      insert(:submission,
        account_id: user.id,
        block_id: block.id,
        status: :pending,
        content: %{
          "type" => "quiz_exam",
          "started_at" => DateTime.utc_now(),
          "questions" => questions,
          "answers" => %{},
          "cheat_count" => 0
        }
      )

      {:ok, _lv, html} = live(conn, ~p"/learn/courses/#{course.id}/exam/#{block.id}")

      refute html =~ "main-sidebar"
      assert html =~ "Final Exam"
      assert html =~ "Questions Navigation"
      assert html =~ "What is 2+2?"
      assert html =~ "Type your answer..."
      assert html =~ "disabled=\"\""
      assert html =~ "Next"
    end
  end

  describe "Exam Navigation & Autosave" do
    setup %{conn: conn, course: course, section: section, user: user} do
      block = insert(:block, section: section, type: :quiz_exam, content: %{"count" => 3})
      questions = generate_dummy_questions()
      q1_id = Enum.at(questions, 0)["id"]
      q2_id = Enum.at(questions, 1)["id"]

      sub =
        insert(:submission,
          account_id: user.id,
          block_id: block.id,
          status: :pending,
          content: %{
            "type" => "quiz_exam",
            "started_at" => DateTime.utc_now(),
            "questions" => questions,
            "answers" => %{},
            "cheat_count" => 0
          }
        )

      {:ok, lv, _html} = live(conn, ~p"/learn/courses/#{course.id}/exam/#{block.id}")

      %{lv: lv, block: block, sub: sub, q1_id: q1_id, q2_id: q2_id}
    end

    test "saves answer, highlights navigation, and navigates to next question", %{
      lv: lv,
      sub: sub,
      q1_id: q1_id
    } do
      lv
      |> form("form", %{"answer" => "4"})
      |> render_change()

      updated_sub = Athena.Repo.get!(Athena.Learning.Submission, sub.id)
      assert updated_sub.content["answers"][q1_id] == "4"

      html =
        lv
        |> form("form")
        |> render_submit()

      assert html =~ "Is water wet?"
      assert html =~ "Yes"

      assert html =~ ~r/phx-value-index="0"[^>]*bg-primary\/10/
    end

    test "jumps to specific question and renders finish button on last question", %{
      lv: lv
    } do
      html = render_click(lv, "jump_to", %{"index" => "2"})

      assert html =~ "Write an essay."
      assert html =~ "Finish &amp; Submit"
      refute html =~ "Next"
    end
  end

  describe "Anti-Cheat System" do
    test "increments cheat count and warns user", %{
      conn: conn,
      course: course,
      section: section,
      user: user
    } do
      block =
        insert(:block,
          section: section,
          type: :quiz_exam,
          content: %{"allowed_blur_attempts" => 3}
        )

      questions = generate_dummy_questions()

      insert(:submission,
        account_id: user.id,
        block_id: block.id,
        status: :pending,
        content: %{
          "type" => "quiz_exam",
          "started_at" => DateTime.utc_now(),
          "questions" => questions,
          "answers" => %{},
          "cheat_count" => 0
        }
      )

      {:ok, lv, _html} = live(conn, ~p"/learn/courses/#{course.id}/exam/#{block.id}")

      html = render_hook(lv, "cheat_detected", %{"reason" => "window_blur"})

      assert html =~ "Violations:"
      assert html =~ "1 / 3"
      assert html =~ "text-error"
    end

    test "fails exam instantly when cheat limit is reached", %{
      conn: conn,
      course: course,
      section: section,
      user: user
    } do
      block =
        insert(:block,
          section: section,
          type: :quiz_exam,
          content: %{"allowed_blur_attempts" => 2}
        )

      questions = generate_dummy_questions()

      sub =
        insert(:submission,
          account_id: user.id,
          block_id: block.id,
          status: :pending,
          content: %{
            "type" => "quiz_exam",
            "started_at" => DateTime.utc_now(),
            "questions" => questions,
            "answers" => %{},
            "cheat_count" => 1
          }
        )

      {:ok, lv, _html} = live(conn, ~p"/learn/courses/#{course.id}/exam/#{block.id}")

      assert {:error, {:live_redirect, %{to: redirect_path}}} =
               render_hook(lv, "cheat_detected", %{"reason" => "window_blur"})

      assert redirect_path == "/learn/courses/#{course.id}"

      updated_sub = Athena.Repo.get!(Athena.Learning.Submission, sub.id)
      assert updated_sub.status == :graded
      assert updated_sub.score == 0
      assert updated_sub.content["cheat_count"] == 2
    end
  end

  describe "Timer Logic" do
    test "submits exam automatically if timer runs out during mount", %{
      conn: conn,
      course: course,
      section: section,
      user: user
    } do
      block = insert(:block, section: section, type: :quiz_exam, content: %{"time_limit" => 10})
      questions = generate_dummy_questions()

      started_at = DateTime.utc_now() |> DateTime.add(-11, :minute)

      sub =
        insert(:submission,
          account_id: user.id,
          block_id: block.id,
          status: :pending,
          content: %{
            "type" => "quiz_exam",
            "started_at" => started_at,
            "questions" => questions,
            "answers" => %{},
            "cheat_count" => 0
          }
        )

      {:error, {:live_redirect, %{to: redirect_path, flash: flash}}} =
        live(conn, ~p"/learn/courses/#{course.id}/exam/#{block.id}")

      assert redirect_path == "/learn/courses/#{course.id}"
      assert flash["success"] == "Exam submitted successfully!"

      updated_sub = Athena.Repo.get!(Athena.Learning.Submission, sub.id)
      assert updated_sub.status == :needs_review
    end

    test "ticks timer and auto-submits when time reaches 0", %{
      conn: conn,
      course: course,
      section: section,
      user: user
    } do
      block = insert(:block, section: section, type: :quiz_exam, content: %{"time_limit" => 10})
      questions = generate_dummy_questions()

      started_at = DateTime.utc_now() |> DateTime.add(-599, :second)

      insert(:submission,
        account_id: user.id,
        block_id: block.id,
        status: :pending,
        content: %{
          "type" => "quiz_exam",
          "started_at" => started_at,
          "questions" => questions,
          "answers" => %{},
          "cheat_count" => 0
        }
      )

      {:ok, lv, html} = live(conn, ~p"/learn/courses/#{course.id}/exam/#{block.id}")

      assert html =~ "animate-pulse"

      Process.sleep(1050)

      assert html =~ ~r/00:0[0-5]/
      Enum.each(1..6, fn _ -> send(lv.pid, :tick) end)
      assert_redirect(lv, "/learn/courses/#{course.id}")
    end
  end
end
