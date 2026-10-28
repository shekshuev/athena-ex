defmodule AthenaWeb.LearnLive.ExamFreshAttemptTest do
  @moduledoc """
  Finishing an attempt that the exam LiveView itself created (opening the
  exam URL directly - a permalink, a bookmark, or a teammate following the
  player's "Continue Assessment" button), as opposed to one the player
  created before navigating here.
  """

  use AthenaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Athena.Factory

  test "an attempt created by the exam LiveView itself can be submitted", %{conn: conn} do
    user = insert(:account)
    conn = init_test_session(conn, %{"account_id" => user.id})
    course = insert(:course)
    insert(:enrollment, account_id: user.id, course_id: course.id)
    section = insert(:section, course: course)

    block =
      insert(:block,
        section: nil,
        section_id: section.id,
        type: :quiz_exam,
        content: %{"count" => 2, "include_tags" => ["exam"], "time_limit" => 60}
      )

    for i <- 1..3 do
      lib =
        insert(:library_block,
          type: :quiz_question,
          tags: ["exam"],
          content: %{
            "question_type" => "exact_match",
            "body" => %{"text" => "Pool #{i}"},
            "correct_answer" => "ok"
          }
        )

      insert(:course_library_block, course: course, library_block: lib)
    end

    {:ok, lv, _} = live(conn, ~p"/learn/courses/#{course.id}/exam/#{block.id}")

    render_click(lv, "finish_exam", %{})

    assert Athena.Repo.get_by(Athena.Learning.Submission,
             account_id: user.id,
             block_id: block.id
           ).status in [:graded, :needs_review]
  end

  test "an attempt the player created first submits fine", %{conn: conn} do
    user = insert(:account)
    conn = init_test_session(conn, %{"account_id" => user.id})
    course = insert(:course)
    insert(:enrollment, account_id: user.id, course_id: course.id)
    section = insert(:section, course: course)

    block =
      insert(:block,
        section: nil,
        section_id: section.id,
        type: :quiz_exam,
        content: %{"count" => 2, "include_tags" => ["exam"], "time_limit" => 60}
      )

    for i <- 1..3 do
      lib =
        insert(:library_block,
          type: :quiz_question,
          tags: ["exam"],
          content: %{
            "question_type" => "exact_match",
            "body" => %{"text" => "Pool #{i}"},
            "correct_answer" => "ok"
          }
        )

      insert(:course_library_block, course: course, library_block: lib)
    end

    {:ok, player, _} = live(conn, ~p"/learn/courses/#{course.id}/play/#{section.id}")
    render_click(player, "start_exam", %{"block_id" => block.id})

    {:ok, lv, _} = live(conn, ~p"/learn/courses/#{course.id}/exam/#{block.id}")
    render_click(lv, "finish_exam", %{})

    assert Athena.Repo.get_by(Athena.Learning.Submission,
             account_id: user.id,
             block_id: block.id
           ).status in [:graded, :needs_review]
  end
end
