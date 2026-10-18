defmodule AthenaWeb.LearnLive.PlayerSurveyTest do
  @moduledoc """
  A `:survey` block in the player.

  Two things are being proved here. First, that it behaves like a block: it
  renders in place and the player never navigates away, unlike `:quiz_exam`
  and `:ticket_exam`. Second, that it collects nothing - asserted as negative
  tests over whole tables, because an engagement row written by some future
  change would not fail any test that only looks at survey code.
  """
  use AthenaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Athena.Factory

  alias Athena.Engagement.Event
  alias Athena.Learning.{BlockProgress, Submission}
  alias Athena.Repo
  alias Athena.Surveys
  alias Athena.Surveys.{SurveyAnswer, SurveyResponse}

  setup %{conn: conn} do
    student = insert(:account)
    conn = init_test_session(conn, %{"account_id" => student.id})
    course = insert(:course)
    section = insert(:section, course: course, title: "Week 1")

    %{conn: conn, student: student, course: course, section: section}
  end

  defp published_survey(opts \\ []) do
    owner = Keyword.get_lazy(opts, :owner, fn -> insert(:account) end)
    {:ok, survey} = Surveys.create_survey(owner, %{"title" => "How is the course going?"})

    questions =
      for type <- Keyword.get(opts, :questions, [:scale, :open_text]) do
        {:ok, question} = Surveys.add_question(survey, type)
        question
      end

    {:ok, published} = Surveys.publish_survey(survey)

    {published, questions}
  end

  defp survey_block(section, survey, content \\ %{}) do
    insert(:block,
      section: section,
      type: :survey,
      order: 10,
      content: Map.merge(%{"survey_id" => survey.id}, content)
    )
  end

  defp enroll_individually(student, course) do
    insert(:enrollment, account_id: student.id, course_id: course.id, status: :active)
  end

  defp enroll_via_cohort(student, course) do
    cohort = insert(:cohort)
    insert(:cohort_membership, cohort_id: cohort.id, account_id: student.id)
    insert(:enrollment, cohort_id: cohort.id, course_id: course.id, status: :active)
    cohort
  end

  defp play(conn, course, section),
    do: live(conn, ~p"/learn/courses/#{course.id}/play/#{section.id}")

  describe "it behaves like a block, not like an exam" do
    setup ctx do
      enroll_individually(ctx.student, ctx.course)
      {survey, questions} = published_survey()
      block = survey_block(ctx.section, survey)

      %{survey: survey, questions: questions, block: block}
    end

    test "the first question renders in place, with no navigation away", ctx do
      {:ok, lv, html} = play(ctx.conn, ctx.course, ctx.section)

      assert html =~ "How is the course going?"
      assert has_element?(lv, "#survey-question-#{hd(ctx.questions).id}")

      # `:quiz_exam` would have rendered a start card and pushed a navigation
      # to its own screen. A survey must not leave the lesson.
      refute has_element?(lv, "a[href*='/exam/']")
      assert has_element?(lv, "#survey-next-#{ctx.block.id}")
    end

    test "no response row is created just by opening the lesson", ctx do
      {:ok, _lv, _html} = play(ctx.conn, ctx.course, ctx.section)

      # Opening a lesson is not answering a survey. Auto-creating a row for
      # everyone who scrolled past would fill the results with empty
      # responses and make the completion funnel meaningless.
      assert Repo.aggregate(SurveyResponse, :count) == 0
    end

    test "answering creates the response lazily and saves the answer", ctx do
      {:ok, lv, _html} = play(ctx.conn, ctx.course, ctx.section)

      render_change(lv, "survey_answer", %{
        "question_id" => hd(ctx.questions).id,
        "value" => %{"number" => "4"}
      })

      assert [response] = Surveys.list_responses(ctx.survey.id)
      assert response.status == :in_progress
      assert response.account_id == ctx.student.id
      assert response.block_id == ctx.block.id
      assert response.course_id == ctx.course.id

      assert [answer] = Surveys.list_answers(response.id)
      assert answer.value_numeric == 4.0
    end

    test "a second answer to the same question replaces the first", ctx do
      {:ok, lv, _html} = play(ctx.conn, ctx.course, ctx.section)
      question = hd(ctx.questions)

      for value <- ["2", "5"] do
        render_change(lv, "survey_answer", %{
          "question_id" => question.id,
          "value" => %{"number" => value}
        })
      end

      assert Repo.aggregate(SurveyAnswer, :count) == 1
      [response] = Surveys.list_responses(ctx.survey.id)
      assert [%{value_numeric: 5.0}] = Surveys.list_answers(response.id)
    end

    test "a malformed answer is dropped rather than stored as nothing", ctx do
      {:ok, lv, _html} = play(ctx.conn, ctx.course, ctx.section)

      render_change(lv, "survey_answer", %{
        "question_id" => hd(ctx.questions).id,
        "value" => %{"number" => "quite good"}
      })

      # A blank is a different finding from a bad entry, so neither is
      # recorded as the other.
      assert Repo.aggregate(SurveyAnswer, :count) == 0
    end

    test "stepping forward and back walks the questions in place", ctx do
      [q1, q2] = ctx.questions
      {:ok, lv, _html} = play(ctx.conn, ctx.course, ctx.section)

      lv |> element("#survey-next-#{ctx.block.id}") |> render_click()
      assert has_element?(lv, "#survey-question-#{q2.id}")

      lv |> element("#survey-back-#{ctx.block.id}") |> render_click()
      assert has_element?(lv, "#survey-question-#{q1.id}")
    end

    test "a skip is recorded as a row, not as silence", ctx do
      {:ok, lv, _html} = play(ctx.conn, ctx.course, ctx.section)

      lv |> element("#survey-skip-#{ctx.block.id}") |> render_click()

      [response] = Surveys.list_responses(ctx.survey.id)
      assert [answer] = Surveys.list_answers(response.id)
      assert answer.skipped
      assert answer.question_id == hd(ctx.questions).id
    end

    test "submitting finishes the response and thanks the student", ctx do
      {:ok, lv, _html} = play(ctx.conn, ctx.course, ctx.section)

      for _ <- 1..2, do: lv |> element("#survey-next-#{ctx.block.id}") |> render_click()

      html = lv |> element("#survey-submit-#{ctx.block.id}") |> render_click()

      assert html =~ "Thank you"

      assert [%{status: :completed, completed_at: %DateTime{}}] =
               Surveys.list_responses(ctx.survey.id)
    end

    test "a finished survey stays finished on the next visit", ctx do
      {:ok, lv, _html} = play(ctx.conn, ctx.course, ctx.section)
      for _ <- 1..2, do: lv |> element("#survey-next-#{ctx.block.id}") |> render_click()
      lv |> element("#survey-submit-#{ctx.block.id}") |> render_click()

      {:ok, lv2, html} = play(ctx.conn, ctx.course, ctx.section)

      assert html =~ "Thank you"
      refute has_element?(lv2, "#survey-next-#{ctx.block.id}")
    end
  end

  describe "resuming" do
    setup ctx do
      enroll_individually(ctx.student, ctx.course)
      {survey, questions} = published_survey(questions: [:scale, :open_text, :numeric])
      block = survey_block(ctx.section, survey)

      %{survey: survey, questions: questions, block: block}
    end

    test "an interrupted survey picks up where it was left", ctx do
      [_q1, q2, _q3] = ctx.questions
      {:ok, lv, _html} = play(ctx.conn, ctx.course, ctx.section)

      render_change(lv, "survey_answer", %{
        "question_id" => hd(ctx.questions).id,
        "value" => %{"number" => "3"}
      })

      lv |> element("#survey-next-#{ctx.block.id}") |> render_click()

      # As if the student closed the tab here.
      {:ok, lv2, _html} = play(ctx.conn, ctx.course, ctx.section)

      assert has_element?(lv2, "#survey-question-#{q2.id}")
    end

    test "answers already given come back filled in", ctx do
      {:ok, lv, _html} = play(ctx.conn, ctx.course, ctx.section)

      render_change(lv, "survey_answer", %{
        "question_id" => hd(ctx.questions).id,
        "value" => %{"number" => "3"}
      })

      {:ok, _lv2, html} = play(ctx.conn, ctx.course, ctx.section)

      assert html =~ ~r/value="3"[^>]*checked/
    end

    test "a partial response is visible to the instructor", ctx do
      {:ok, lv, _html} = play(ctx.conn, ctx.course, ctx.section)

      render_change(lv, "survey_answer", %{
        "question_id" => hd(ctx.questions).id,
        "value" => %{"number" => "3"}
      })

      # Never submitted, and that is exactly what makes it interesting:
      # abandonment is feedback about the question.
      assert [%{status: :in_progress} = response] = Surveys.list_responses(ctx.survey.id)
      assert length(Surveys.list_answers(response.id)) == 1
    end
  end

  describe "attribution" do
    test "a student enrolled through a cohort is recorded against the cohort", ctx do
      cohort = enroll_via_cohort(ctx.student, ctx.course)
      {survey, questions} = published_survey()
      survey_block(ctx.section, survey)

      {:ok, lv, _html} = play(ctx.conn, ctx.course, ctx.section)

      render_change(lv, "survey_answer", %{
        "question_id" => hd(questions).id,
        "value" => %{"number" => "4"}
      })

      assert [response] = Surveys.list_responses(survey.id)
      assert response.cohort_id == cohort.id
    end

    test "an individually enrolled student has no cohort to be grouped into", ctx do
      enroll_individually(ctx.student, ctx.course)
      {survey, questions} = published_survey()
      survey_block(ctx.section, survey)

      {:ok, lv, _html} = play(ctx.conn, ctx.course, ctx.section)

      render_change(lv, "survey_answer", %{
        "question_id" => hd(questions).id,
        "value" => %{"number" => "4"}
      })

      assert [response] = Surveys.list_responses(survey.id)
      assert response.cohort_id == nil
    end
  end

  describe "it collects nothing" do
    setup ctx do
      enroll_individually(ctx.student, ctx.course)
      {survey, questions} = published_survey()
      block = survey_block(ctx.section, survey)

      %{survey: survey, questions: questions, block: block}
    end

    test "the block carries no data-block-id, so the tracker never sees it", ctx do
      {:ok, _lv, html} = play(ctx.conn, ctx.course, ctx.section)

      # The tracker finds nodes by this attribute. Its absence is the
      # exclusion at the source; `data-engagement="off"` says so out loud.
      refute html =~ ~s(data-block-id="#{ctx.block.id}")
      assert html =~ ~s(data-engagement="off")
    end

    test "a batch naming a survey block writes no engagement rows at all", ctx do
      {:ok, lv, _html} = play(ctx.conn, ctx.course, ctx.section)

      # A client is a client: the server is the authority, so this asserts the
      # filter, not the markup.
      render_hook(lv, "engagement_batch", %{
        "events" => [
          %{
            "block_id" => ctx.block.id,
            "event_type" => "viewport_enter",
            "occurred_at" => DateTime.utc_now() |> DateTime.to_iso8601()
          },
          %{
            "block_id" => ctx.block.id,
            "event_type" => "typing_summary",
            "occurred_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
            "payload" => %{"keystrokes" => 40}
          }
        ]
      })

      assert Repo.aggregate(Event, :count) == 0
    end

    test "events for other blocks in the same batch are still recorded", ctx do
      text = insert(:block, section: ctx.section, type: :text, order: 20)
      {:ok, lv, _html} = play(ctx.conn, ctx.course, ctx.section)

      render_hook(lv, "engagement_batch", %{
        "events" => [
          %{
            "block_id" => ctx.block.id,
            "event_type" => "viewport_enter",
            "occurred_at" => DateTime.utc_now() |> DateTime.to_iso8601()
          },
          %{
            "block_id" => text.id,
            "event_type" => "viewport_enter",
            "occurred_at" => DateTime.utc_now() |> DateTime.to_iso8601()
          }
        ]
      })

      # The filter is surgical, not a blanket switch-off for the page.
      block_ids = Repo.all(Event) |> Enum.map(& &1.block_id)
      assert block_ids == [text.id]
    end

    test "answering a whole survey leaves no trace in any other table", ctx do
      {:ok, lv, _html} = play(ctx.conn, ctx.course, ctx.section)

      render_change(lv, "survey_answer", %{
        "question_id" => hd(ctx.questions).id,
        "value" => %{"number" => "4"}
      })

      lv |> element("#survey-next-#{ctx.block.id}") |> render_click()

      render_change(lv, "survey_answer", %{
        "question_id" => Enum.at(ctx.questions, 1).id,
        "value" => %{"text" => "More lab time please"}
      })

      lv |> element("#survey-next-#{ctx.block.id}") |> render_click()
      lv |> element("#survey-submit-#{ctx.block.id}") |> render_click()

      # Negative assertions over whole tables, deliberately: a row written by
      # some future change would not fail a test that only reads survey code.
      assert Repo.aggregate(Event, :count) == 0
      assert Repo.aggregate(Submission, :count) == 0

      # The gate row is account-keyed, so it may exist - but it must carry no
      # answers in its payload.
      for progress <- Repo.all(BlockProgress) do
        assert progress.payload in [nil, %{}]
      end
    end

    test "a survey cannot be a library block, so no exam can contain one" do
      # This is why `Exam` and `TicketExam` need no survey filter of their own:
      # an exam assembles itself from library blocks, and :survey is not one.
      refute :survey in Athena.Content.BlockTypes.library()
      refute :survey in Athena.Content.BlockTypes.xp_awardable()
      refute Athena.Content.Block.gradable?(:survey)
    end
  end

  describe "the completion gate" do
    test "submitting satisfies a :submit completion rule like any other block", ctx do
      enroll_individually(ctx.student, ctx.course)
      {survey, _questions} = published_survey(questions: [:scale])

      block =
        insert(:block,
          section: ctx.section,
          type: :survey,
          order: 10,
          content: %{"survey_id" => survey.id},
          completion_rule: %Athena.Content.CompletionRule{type: :submit}
        )

      insert(:block, section: ctx.section, type: :text, order: 20)

      {:ok, lv, _html} = play(ctx.conn, ctx.course, ctx.section)

      lv |> element("#survey-next-#{block.id}") |> render_click()
      lv |> element("#survey-submit-#{block.id}") |> render_click()

      # The ordinary gate: nothing about surveys is special here, which is the
      # point - `calc_visible_blocks/2` and the section's own progression work
      # unchanged.
      assert block.id in Athena.Learning.completed_block_ids(ctx.student.id, ctx.section.id, nil)
    end

    test "submitting twice does not re-mark the gate", ctx do
      enroll_individually(ctx.student, ctx.course)
      {survey, _questions} = published_survey(questions: [:scale])

      block =
        insert(:block,
          section: ctx.section,
          type: :survey,
          order: 10,
          content: %{"survey_id" => survey.id},
          completion_rule: %Athena.Content.CompletionRule{type: :submit}
        )

      {:ok, lv, _html} = play(ctx.conn, ctx.course, ctx.section)
      lv |> element("#survey-next-#{block.id}") |> render_click()
      lv |> element("#survey-submit-#{block.id}") |> render_click()

      render_click(lv, "survey_submit", %{"block_id" => block.id})

      assert Repo.aggregate(BlockProgress, :count) == 1
    end
  end

  describe "misconfiguration is visible, not fatal" do
    setup ctx do
      enroll_individually(ctx.student, ctx.course)
      :ok
    end

    test "a block pointing at a deleted survey renders a notice", ctx do
      insert(:block,
        section: ctx.section,
        type: :survey,
        order: 10,
        content: %{"survey_id" => Ecto.UUID.generate()}
      )

      {:ok, _lv, html} = play(ctx.conn, ctx.course, ctx.section)

      assert html =~ "could not be loaded"
    end

    test "an unpublished survey tells the student to wait rather than showing questions", ctx do
      owner = insert(:account)
      {:ok, survey} = Surveys.create_survey(owner, %{"title" => "Draft feedback"})
      {:ok, question} = Surveys.add_question(survey, :scale)
      survey_block(ctx.section, survey)

      {:ok, lv, html} = play(ctx.conn, ctx.course, ctx.section)

      assert html =~ "not published this survey yet"
      refute has_element?(lv, "#survey-question-#{question.id}")
      assert Repo.aggregate(SurveyResponse, :count) == 0
    end

    test "a closed survey accepts nothing more", ctx do
      {survey, questions} = published_survey()
      {:ok, _closed} = Surveys.close_survey(survey)
      survey_block(ctx.section, survey)

      {:ok, lv, html} = play(ctx.conn, ctx.course, ctx.section)

      assert html =~ "closed and no longer accepts"

      render_change(lv, "survey_answer", %{
        "question_id" => hd(questions).id,
        "value" => %{"number" => "4"}
      })

      assert Repo.aggregate(SurveyResponse, :count) == 0
    end

    test "a title override renames the survey for this course only", ctx do
      {survey, _questions} = published_survey()
      survey_block(ctx.section, survey, %{"title_override" => "Week 1 check-in"})

      {:ok, _lv, html} = play(ctx.conn, ctx.course, ctx.section)

      assert html =~ "Week 1 check-in"
      assert Surveys.get_survey(survey.id).title == "How is the course going?"
    end
  end
end
