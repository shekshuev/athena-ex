defmodule AthenaWeb.LearnLive.PlayerTeamExamTest do
  @moduledoc """
  How `:quiz_exam` / `:ticket_exam` blocks behave for a competition team
  (`:team` cohort), where every other kind of block shares one row per
  `(cohort_id, block_id)`.
  """
  use AthenaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Athena.Factory
  import Ecto.Query

  alias Athena.Content.CompletionRule
  alias Athena.Learning.Submission
  alias Athena.Repo

  setup %{conn: conn} do
    alice = insert(:account)
    bob = insert(:account)

    course = insert(:course, type: :competition)
    team = insert(:cohort, type: :team)

    insert(:enrollment, course_id: course.id, cohort_id: team.id)
    insert(:cohort_membership, account_id: alice.id, cohort_id: team.id)
    insert(:cohort_membership, account_id: bob.id, cohort_id: team.id)

    section = insert(:section, course: course)

    %{
      alice_conn: init_test_session(conn, %{"account_id" => alice.id}),
      bob_conn: init_test_session(Phoenix.ConnTest.build_conn(), %{"account_id" => bob.id}),
      alice: alice,
      bob: bob,
      course: course,
      team: team,
      section: section
    }
  end

  describe "one attempt per team, or one per member?" do
    test "each member starting the exam gets a separate attempt with its own questions", ctx do
      block = exam_block(ctx.section)
      seed_question_pool(ctx.course, 6)

      {:ok, alice_lv, _} = live(ctx.alice_conn, play_path(ctx.course, ctx.section))
      render_click(alice_lv, "start_exam", %{"block_id" => block.id})

      {:ok, bob_lv, bob_html} = live(ctx.bob_conn, play_path(ctx.course, ctx.section))

      # Bob is told the team's assessment is already under way...
      assert bob_html =~ "Continue Assessment"

      # ...and "continuing" it is what actually starts a second one.
      render_click(bob_lv, "continue_exam", %{"block_id" => block.id})
      {:ok, _bob_exam, _} = live(ctx.bob_conn, exam_path(ctx.course, block))

      attempts = team_attempts(block.id)

      assert length(attempts) == 1,
             "the team ended up with #{length(attempts)} parallel attempts at one exam block"
    end

    test "the two attempts are not even the same exam paper", ctx do
      block = exam_block(ctx.section)
      seed_question_pool(ctx.course, 6)

      {:ok, _alice_exam, _} = live(ctx.alice_conn, exam_path(ctx.course, block))
      {:ok, _bob_exam, _} = live(ctx.bob_conn, exam_path(ctx.course, block))

      [alice_paper, bob_paper] = Enum.map(team_attempts(block.id), &question_texts/1)

      assert alice_paper == bob_paper,
             "team members sat different papers for the same exam block"
    end

    test "answers one member types are not visible to the other", ctx do
      block = exam_block(ctx.section)
      seed_question_pool(ctx.course, 6)

      {:ok, alice_exam, _} = live(ctx.alice_conn, exam_path(ctx.course, block))

      [attempt] = team_attempts(block.id)
      first_question_id = attempt.content["questions"] |> hd() |> Map.fetch!("id")

      alice_exam
      |> form("#exam-quiz-#{first_question_id}", %{"answer" => "alice's exam answer"})
      |> render_change()

      {:ok, _bob_exam, bob_html} = live(ctx.bob_conn, exam_path(ctx.course, block))

      assert bob_html =~ "alice's exam answer",
             "the team's exam answers are not shared the way every other block's are"
    end
  end

  describe "what the team's score ends up being" do
    test "a teammate's ungraded attempt does not wipe the team's graded score", ctx do
      block = exam_block(ctx.section)

      # Alice finished and scored 90.
      insert(:submission,
        account_id: ctx.alice.id,
        cohort_id: ctx.team.id,
        block_id: block.id,
        status: :graded,
        score: 90,
        content: %{"type" => "quiz_exam", "questions" => []}
      )

      # Bob sat the same exam; his essay answers await the instructor, so
      # his attempt carries no score yet.
      unscored =
        insert(:submission,
          account_id: ctx.bob.id,
          cohort_id: ctx.team.id,
          block_id: block.id,
          status: :needs_review,
          content: %{"type" => "quiz_exam", "questions" => []}
        )

      null_out_score(unscored)

      [team_row] = Athena.Learning.get_team_leaderboard(ctx.course.id)

      assert team_row.total_score == 90,
             "an unscored attempt masked the team's graded result (got #{team_row.total_score})"
    end

    test "the player shows the team's graded result, not a teammate's blank one", ctx do
      block = exam_block(ctx.section)

      insert(:submission,
        account_id: ctx.alice.id,
        cohort_id: ctx.team.id,
        block_id: block.id,
        status: :graded,
        score: 90,
        content: %{"type" => "quiz_exam", "questions" => []}
      )

      insert(:submission,
        account_id: ctx.bob.id,
        cohort_id: ctx.team.id,
        block_id: block.id,
        status: :needs_review,
        content: %{"type" => "quiz_exam", "questions" => []}
      )
      |> null_out_score()

      {:ok, _bob_lv, html} = live(ctx.bob_conn, play_path(ctx.course, ctx.section))

      assert html =~ "90 / 100",
             "the player showed an unscored attempt instead of the team's 90"
    end
  end

  describe "the exam as a gate" do
    test "the first member to finish opens the gate for the whole team, live", ctx do
      block =
        insert(:block,
          section: nil,
          section_id: ctx.section.id,
          order: 10,
          type: :quiz_exam,
          completion_rule: %CompletionRule{type: :submit},
          content: %{"count" => 2, "include_tags" => ["exam"], "time_limit" => 60}
        )

      insert(:block,
        section: nil,
        section_id: ctx.section.id,
        order: 20,
        content: %{"text" => "Behind the exam"}
      )

      seed_question_pool(ctx.course, 4)

      {:ok, alice_player, _} = live(ctx.alice_conn, play_path(ctx.course, ctx.section))
      render_click(alice_player, "start_exam", %{"block_id" => block.id})
      {:ok, alice_exam, _} = live(ctx.alice_conn, exam_path(ctx.course, block))

      {:ok, bob_lv, bob_html} = live(ctx.bob_conn, play_path(ctx.course, ctx.section))

      refute bob_html =~ "Behind the exam"

      render_click(alice_exam, "finish_exam", %{})

      assert render(bob_lv) =~ "Behind the exam",
             "finishing the team's exam did not move the waterline for the rest of the team"
    end
  end

  defp play_path(course, section), do: ~p"/learn/courses/#{course.id}/play/#{section.id}"
  defp exam_path(course, block), do: ~p"/learn/courses/#{course.id}/exam/#{block.id}"

  defp exam_block(section) do
    insert(:block,
      section: nil,
      section_id: section.id,
      type: :quiz_exam,
      content: %{"count" => 3, "include_tags" => ["exam"], "time_limit" => 60}
    )
  end

  defp seed_question_pool(course, n) do
    for i <- 1..n do
      lib =
        insert(:library_block,
          type: :quiz_question,
          tags: ["exam"],
          content: %{
            "question_type" => "open",
            "body" => %{"text" => "Pool question #{i}"}
          }
        )

      insert(:course_library_block, course: course, library_block: lib)
    end
  end

  defp team_attempts(block_id) do
    Submission
    |> where([s], s.block_id == ^block_id and is_nil(s.parent_submission_id))
    |> order_by([s], asc: s.inserted_at)
    |> Repo.all()
  end

  # `score` has a database default of 0 and Ecto leaves nil fields out of an
  # insert, so an attempt that genuinely has no score yet has to be written
  # as NULL on purpose.
  defp null_out_score(%Submission{id: id} = submission) do
    {1, _} = Submission |> where([s], s.id == ^id) |> Repo.update_all(set: [score: nil])
    submission
  end

  defp question_texts(%Submission{content: content}) do
    (content["questions"] || [])
    |> Enum.map(&get_in(&1, ["content", "body", "text"]))
    |> Enum.sort()
  end
end
