defmodule AthenaWeb.LearnLive.PlayerReadonlyTest do
  use AthenaWeb.ConnCase, async: true
  use Oban.Testing, repo: Athena.Repo

  import Athena.Factory
  import Phoenix.LiveViewTest
  import Ecto.Query

  alias Athena.{Learning, Repo}
  alias Athena.Content.CompletionRule
  alias Athena.Learning.Submission

  setup %{conn: conn} do
    user = insert(:account)
    course = insert(:course)
    insert(:enrollment, account_id: user.id, course_id: course.id)
    section = insert(:section, course: course, interaction_mode: :readonly)
    conn = init_test_session(conn, %{"account_id" => user.id})
    %{conn: conn, user: user, course: course, section: section}
  end

  test "shows submitted code and feedback without reading execution results or drafts", ctx do
    block = code_block(ctx.section)
    large_result = %{"stdout" => String.duplicate("oversized-result", 10_000)}

    insert(:submission,
      account_id: ctx.user.id,
      block_id: block.id,
      status: :graded,
      score: 60,
      feedback: "Instructor feedback",
      content: %{"type" => "code", "code" => "SELECT 42", "execution_results" => [large_result]}
    )

    insert(:submission,
      account_id: ctx.user.id,
      block_id: block.id,
      status: :draft,
      content: %{"type" => "code", "code" => "SELECT 99", "execution_results" => [large_result]}
    )

    {:ok, view, _} = live(ctx.conn, path(ctx))
    assert has_element?(view, "#readonly-notice-#{block.id}")

    assert has_element?(
             view,
             "[id^='code-editor-readonly-'][data-readonly='true'][data-code='SELECT 42']"
           )

    assert has_element?(view, "#instructor-feedback-#{block.id}")
    assert has_element?(view, "#readonly-score-#{block.id}", "60 / 100")
    refute has_element?(view, "#code-form-#{block.id}")
    refute has_element?(view, "[phx-click='run_code']")

    assigns = :sys.get_state(view.pid).socket.assigns
    refute Map.has_key?(assigns.submissions[block.id].content, "execution_results")
    refute Map.has_key?(assigns.drafts, block.id)

    # The same projection is used by mount and real-time refreshes.
    assert %{content: %{"code" => "SELECT 42"} = content} =
             Learning.get_latest_submissions(ctx.user.id, [block.id], nil,
               readonly_code_ids: [block.id]
             )[block.id]

    refute Map.has_key?(content, "execution_results")
  end

  test "rejects crafted run, submit and draft events without changing answers", ctx do
    block = code_block(ctx.section)
    {:ok, view, _} = live(ctx.conn, path(ctx))

    for event <- ["run_code", "submit_code", "save_draft"] do
      render_click(view, event, %{"block_id" => block.id, "answer" => %{"code" => "SELECT 1"}})
    end

    refute Repo.exists?(from(s in Submission, where: s.block_id == ^block.id))
    assert all_enqueued(worker: Athena.Execution.TestWorker) == []
    assert {:error, :readonly} = Learning.save_draft(ctx.user, block.id, %{"code" => "SELECT 1"})

    assert {:error, :readonly} =
             Learning.create_submission(ctx.user, %{"block_id" => block.id, "content" => %{}})
  end

  test "updates an open player in both directions and rejects actions before refresh", ctx do
    block = code_block(ctx.section)

    section =
      ctx.section |> Ecto.Changeset.change(interaction_mode: :interactive) |> Repo.update!()

    {:ok, view, _} = live(ctx.conn, path(ctx))
    assert has_element?(view, "#code-form-#{block.id}")

    # No PubSub yet: even a stale interactive page must obey persisted policy.
    section = section |> Ecto.Changeset.change(interaction_mode: :readonly) |> Repo.update!()

    render_click(view, "save_draft", %{
      "block_id" => block.id,
      "answer" => %{"code" => "SELECT 9"}
    })

    refute Repo.exists?(from(s in Submission, where: s.block_id == ^block.id))

    Phoenix.PubSub.broadcast(Athena.PubSub, "course_content:#{ctx.course.id}", :refresh_content)
    assert has_element?(view, "#readonly-notice-#{block.id}")
    refute has_element?(view, "#code-form-#{block.id}")

    section |> Ecto.Changeset.change(interaction_mode: :interactive) |> Repo.update!()
    Phoenix.PubSub.broadcast(Athena.PubSub, "course_content:#{ctx.course.id}", :refresh_content)
    assert has_element?(view, "#code-form-#{block.id}")
    refute has_element?(view, "#readonly-notice-#{block.id}")
  end

  test "explicit block override remains writable; readonly keeps the waterline", ctx do
    first = code_block(ctx.section, interaction_mode: :interactive, order: 10)

    gate =
      insert(:block,
        section: ctx.section,
        order: 20,
        completion_rule: %CompletionRule{type: :button}
      )

    last = code_block(ctx.section, order: 30)
    {:ok, view, _} = live(ctx.conn, path(ctx))
    assert has_element?(view, "#code-form-#{first.id}")
    assert has_element?(view, "#readonly-notice-#{gate.id}")
    refute has_element?(view, "#block-wrapper-#{last.id}")
    render_click(view, "complete_gate", %{"block-id" => gate.id, "block_id" => first.id})
    refute has_element?(view, "#block-wrapper-#{last.id}")
    refute gate.id in Learning.completed_block_ids(ctx.user.id, ctx.section.id)
  end

  test "quiz and file blocks are visible without editing or revealing correct answers", ctx do
    quiz =
      insert(:block,
        section: ctx.section,
        type: :quiz_question,
        content: %{
          "question_type" => "exact_match",
          "body" => %{"text" => "Question"},
          "correct_answer" => "SECRET"
        }
      )

    file = insert(:block, section: ctx.section, type: :file_assignment, order: 20)
    {:ok, view, _} = live(ctx.conn, path(ctx))
    assert has_element?(view, "#readonly-notice-#{quiz.id}")
    assert has_element?(view, "#readonly-notice-#{file.id}")
    refute has_element?(view, "#quiz-form-#{quiz.id}")
    refute has_element?(view, "#file-assignment-form-#{file.id}")
    refute has_element?(view, "[phx-click='request_media_upload']")
    refute has_element?(view, "#block-wrapper-#{quiz.id} .text-success", "SECRET")
  end

  test "direct assessment URLs cannot start readonly exams", ctx do
    for {type, route} <- [{:quiz_exam, "exam"}, {:ticket_exam, "ticket"}] do
      block =
        insert(:block,
          section: ctx.section,
          type: type,
          content: %{"time_limit" => 30, "count" => 1}
        )

      assert {:error, {:live_redirect, _}} =
               live(ctx.conn, "/learn/courses/#{ctx.course.id}/#{route}/#{block.id}")

      refute Repo.exists?(from(s in Submission, where: s.block_id == ^block.id))
    end
  end

  test "readonly broadcasts never reintroduce large submission or draft content", ctx do
    block = code_block(ctx.section)

    submission =
      insert(:submission,
        account_id: ctx.user.id,
        block_id: block.id,
        status: :graded,
        content: %{"type" => "code", "code" => "SELECT 1"}
      )

    {:ok, view, _} = live(ctx.conn, path(ctx))

    content =
      Map.put(submission.content, "execution_results", [
        %{"stdout" => String.duplicate("large", 10_000)}
      ])

    send(view.pid, {:submission_updated, %{submission | content: content}})

    send(
      view.pid,
      {:draft_updated, %{block_id: block.id, content: content, updater_id: "test_worker"}}
    )

    assert has_element?(view, "#readonly-notice-#{block.id}")
    assigns = :sys.get_state(view.pid).socket.assigns
    refute Map.has_key?(assigns.submissions[block.id].content, "execution_results")
    refute Map.has_key?(assigns.drafts, block.id)
  end

  test "open assessments stop on readonly without submitting or changing results", ctx do
    for {type, route} <- [{:quiz_exam, "exam"}, {:ticket_exam, "ticket"}] do
      block =
        insert(:block,
          section: ctx.section,
          type: type,
          interaction_mode: :interactive,
          content: %{"time_limit" => 30, "count" => 1}
        )

      question_id = Ecto.UUID.generate()

      attempt =
        insert(:submission,
          account_id: ctx.user.id,
          block_id: block.id,
          status: :pending,
          expires_at: DateTime.add(DateTime.utc_now(:second), 1800),
          content: %{
            "questions" => [
              %{
                "id" => question_id,
                "type" => "quiz_question",
                "content" => %{"question_type" => "open", "body" => %{"text" => "Question"}}
              }
            ]
          }
        )

      {:ok, view, _} = live(ctx.conn, "/learn/courses/#{ctx.course.id}/#{route}/#{block.id}")
      block |> Ecto.Changeset.change(interaction_mode: :readonly) |> Repo.update!()
      render_click(view, "finish_exam", %{})
      assert Repo.get!(Submission, attempt.id).status == :pending
      Phoenix.PubSub.broadcast(Athena.PubSub, "course_content:#{ctx.course.id}", :refresh_content)
      assert_redirect(view, path(ctx))
      assert Repo.get!(Submission, attempt.id).status == :pending
    end
  end

  test "readonly surveys show questions but never accept answers", ctx do
    {:ok, survey} = Athena.Surveys.create_survey(ctx.user, %{"title" => "Feedback"})
    {:ok, question} = Athena.Surveys.add_question(survey, :open_text)
    {:ok, later_question} = Athena.Surveys.add_question(survey, :open_text)
    {:ok, survey} = Athena.Surveys.publish_survey(survey)

    block =
      insert(:block, section: ctx.section, type: :survey, content: %{"survey_id" => survey.id})

    {:ok, view, _} = live(ctx.conn, path(ctx))
    assert has_element?(view, "#survey-question-#{question.id}")
    refute has_element?(view, "#survey-next-#{block.id}")

    for question <- [question, later_question] do
      render_click(view, "survey_answer", %{
        "question_id" => question.id,
        "block_id" => Ecto.UUID.generate(),
        "value" => %{"text" => "changed"}
      })
    end

    render_click(view, "survey_submit", %{"block_id" => block.id})
    refute Repo.exists?(Athena.Surveys.SurveyResponse)
  end

  defp path(ctx), do: ~p"/learn/courses/#{ctx.course.id}/play/#{ctx.section.id}"

  defp code_block(section, attrs \\ []) do
    insert(
      :block,
      Keyword.merge(
        [
          section: section,
          type: :code,
          content: %{"language" => "sql", "initial_code" => "SELECT 0"}
        ],
        attrs
      )
    )
  end
end
