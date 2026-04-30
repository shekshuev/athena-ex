defmodule AthenaWeb.StudioLive.GradingDetailTest do
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

      {:ok, _lv, html} = live(conn, ~p"/studio/grading/#{sub.id}")

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

      {:ok, _lv, html} = live(conn, ~p"/studio/grading/#{sub.id}")

      assert html =~ "Submission from tolstoy"
      assert html =~ "War and Peace. Volume 1."
      assert html =~ "<textarea"
      assert html =~ ~r/ disabled(?!:)/
    end
  end

  describe "Grading Detail (Exam & Cheating)" do
    test "renders exam with questions, open review badges, and cheat violations", %{conn: conn} do
      student = insert(:account, login: "sneaky_student")
      block = insert(:block, type: :quiz_exam)

      sub =
        insert(:submission,
          account_id: student.id,
          block_id: block.id,
          content: %{
            "cheat_count" => 2,
            "questions" => [
              %{"id" => "q1", "question_type" => "open", "body" => %{"text" => "Question 1"}},
              %{
                "id" => "q2",
                "question_type" => "single",
                "options" => [%{"id" => "o1", "text" => "Opt 1"}]
              }
            ],
            "answers" => %{"q1" => "I don't know", "q2" => "o1"}
          },
          status: :needs_review
        )

      {:ok, _lv, html} = live(conn, ~p"/studio/grading/#{sub.id}")

      assert html =~ "sneaky_student"

      assert html =~ "quiz exam"

      assert html =~ "Manual Review"
      assert html =~ "I don&#39;t know"

      assert html =~ "Cheating Detected"
      assert html =~ "triggered 2 window blur violations"
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

      {:ok, _lv, html} = live(conn, ~p"/studio/grading/#{sub.id}")

      refute html =~ "Cheating Detected"
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

      {:ok, lv, _html} = live(conn, ~p"/studio/grading/#{sub.id}")

      lv
      |> form("#grading-form", %{"score" => "85", "feedback" => "Good essay, bro!"})
      |> render_submit(%{"action" => "grade"})
      |> follow_redirect(conn, ~p"/studio/grading")

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

      {:ok, lv, _html} = live(conn, ~p"/studio/grading/#{sub.id}")

      lv
      |> form("#grading-form", %{"score" => "85", "feedback" => "Very bad!"})
      |> render_submit(%{"action" => "reject"})

      assert_redirect(lv, "/studio/grading")

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

      assert {:error, redirect} = live(conn, ~p"/studio/grading/#{sub.id}")

      case redirect do
        {:redirect, %{to: _path}} -> assert true
        {:live_redirect, %{to: _path}} -> assert true
        _ -> flunk("Expected a redirect due to lack of permissions")
      end
    end
  end
end
