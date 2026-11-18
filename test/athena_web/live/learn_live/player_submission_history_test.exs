defmodule AthenaWeb.LearnLive.PlayerSubmissionHistoryTest do
  use AthenaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Athena.Factory
  alias Athena.{Learning, Repo}
  alias Athena.Learning.{DraftCache, Submission}

  setup %{conn: conn} do
    user = insert(:account)
    course = insert(:course)
    insert(:enrollment, account_id: user.id, course_id: course.id)
    section = insert(:section, course: course)

    block =
      insert(:block,
        section: section,
        type: :code,
        content: %{"language" => "sql", "initial_code" => "SELECT 0"}
      )

    %{
      conn: init_test_session(conn, %{"account_id" => user.id}),
      user: user,
      course: course,
      section: section,
      block: block
    }
  end

  test "draft is editable, submitted code can be inspected, discard clears the editor", ctx do
    old = sent(ctx, "SELECT 80", 80, ~U[2026-01-01 10:00:00Z], "Old comment")
    latest = sent(ctx, "SELECT 40", 40, ~U[2026-01-02 10:00:00Z], "Latest comment")

    {:ok, draft} =
      Learning.save_draft(ctx.user, ctx.block.id, %{"type" => "code", "code" => "SELECT 'draft'"})

    {:ok, view, _} = live(ctx.conn, path(ctx))
    revision = DraftCache.revision(ctx.user.id, nil, ctx.block.id)

    assert has_element?(
             view,
             "#code-form-#{ctx.block.id} [data-code=\"SELECT 'draft'\"][data-readonly='false']"
           )

    assert has_element?(view, "#submitted-solution-#{ctx.block.id} [data-code='SELECT 40']")
    assert has_element?(view, "#instructor-feedback-#{ctx.block.id}", "Latest comment")
    assert has_element?(view, "#feedback-submission-note-#{ctx.block.id}")
    refute has_element?(view, "#instructor-feedback-#{ctx.block.id}", "Old comment")
    assert has_element?(view, "#block-wrapper-#{ctx.block.id} > details:last-child")

    assert has_element?(
             view,
             "#block-wrapper-#{ctx.block.id} > div:has(> #discard-draft-#{ctx.block.id}) + #submitted-solution-#{ctx.block.id}"
           )

    refute has_element?(view, "#discard-draft-#{ctx.block.id}[data-confirm]")
    view |> element("#discard-draft-#{ctx.block.id}") |> render_click()
    assert has_element?(view, "#discard-draft-modal.modal-open")
    assert Repo.get!(Submission, draft.id)
    view |> element("#discard-draft-modal button", "Cancel") |> render_click()
    refute has_element?(view, "#discard-draft-modal.modal-open")
    assert Repo.get!(Submission, draft.id)
    view |> element("#discard-draft-#{ctx.block.id}") |> render_click()
    view |> element("#discard-draft-modal button", "Delete draft") |> render_click()
    refute has_element?(view, "#discard-draft-modal.modal-open")
    refute has_element?(view, "#discard-draft-#{ctx.block.id}")
    assert has_element?(view, "#submitted-solution-#{ctx.block.id} [data-code='SELECT 40']")
    assert has_element?(view, "#code-form-#{ctx.block.id} [data-code='']")
    assert Repo.get(Submission, draft.id) == nil
    assert Repo.get!(Submission, latest.id).score == 40
    assert Repo.get!(Submission, old.id).score == 80

    render_click(view, "save_draft", %{
      "block_id" => ctx.block.id,
      "draft_revision" => revision,
      "answer" => %{"code" => "LATE AUTOSAVE"}
    })

    render_click(view, "update_content", %{
      "id" => ctx.block.id,
      "draft_revision" => revision,
      "content" => "LATE RICH TEXT"
    })

    assert Learning.get_draft(ctx.user.id, ctx.block.id) == nil
    assert has_element?(view, "#code-form-#{ctx.block.id} [data-code='']")
  end

  test "discard clears a quiz answer while keeping its submitted answer available", ctx do
    ctx.block
    |> Ecto.Changeset.change(
      type: :quiz_question,
      content: %{"question_type" => "exact_match", "correct_answer" => "42"}
    )
    |> Repo.update!()

    insert(:submission,
      account_id: ctx.user.id,
      block_id: ctx.block.id,
      status: :graded,
      score: 40,
      content: %{"type" => "quiz_question", "text_answer" => "old answer"}
    )

    Learning.save_draft(ctx.user, ctx.block.id, %{"text_answer" => "draft answer"})
    {:ok, view, _} = live(ctx.conn, path(ctx))
    assert has_element?(view, "#exact-answer-#{ctx.block.id}[value='draft answer']")
    view |> element("#discard-draft-#{ctx.block.id}") |> render_click()
    view |> element("#discard-draft-modal button", "Delete draft") |> render_click()

    refute has_element?(view, "#exact-answer-#{ctx.block.id}[value='old answer']")
    refute has_element?(view, "#exact-answer-#{ctx.block.id}[value='draft answer']")
    assert has_element?(view, "#exact-answer-submitted-#{ctx.block.id}[value='old answer']")
    assert Learning.get_draft(ctx.user.id, ctx.block.id) == nil
  end

  test "late grading of an old attempt cannot replace the latest code or comment", ctx do
    old = sent(ctx, "SELECT 80", 80, ~U[2026-01-01 10:00:00Z], "Old comment")
    sent(ctx, "SELECT 40", 40, ~U[2026-01-02 10:00:00Z], "Latest comment")
    {:ok, view, _} = live(ctx.conn, path(ctx))

    {:ok, changed} =
      Learning.system_update_submission(old, %{score: 90, feedback: "Regraded old"})

    send(view.pid, {:submission_updated, changed})
    assert has_element?(view, "#code-form-#{ctx.block.id} [data-code='SELECT 40']")
    assert has_element?(view, "#instructor-feedback-#{ctx.block.id}", "Latest comment")
    refute has_element?(view, "#instructor-feedback-#{ctx.block.id}", "Regraded old")
  end

  test "an old rejection remains a restriction, but does not replace the displayed submission",
       ctx do
    sent(ctx, "SELECT 0", 0, ~U[2026-01-01 10:00:00Z], "Rejected")
    |> Ecto.Changeset.change(status: :rejected)
    |> Repo.update!()

    sent(ctx, "SELECT 40", 40, ~U[2026-01-02 10:00:00Z], "Latest comment")
    {:ok, view, _} = live(ctx.conn, path(ctx))
    assert has_element?(view, "#block-wrapper-#{ctx.block.id} [data-code='SELECT 40']")
    assert has_element?(view, "#review-notice-#{ctx.block.id}")

    render_click(view, "submit_code", %{
      "block_id" => ctx.block.id,
      "answer" => %{"code" => "SELECT 2"}
    })

    assert Repo.aggregate(Submission, :count) == 2
  end

  test "readonly ignores the draft, shows the latest send and has no discard control", ctx do
    sent(ctx, "SELECT 80", 80, ~U[2026-01-01 10:00:00Z], "Old")
    sent(ctx, "SELECT 40", 40, ~U[2026-01-02 10:00:00Z], "Latest")
    Learning.save_draft(ctx.user, ctx.block.id, %{"code" => "DRAFT"})
    ctx.block |> Ecto.Changeset.change(interaction_mode: :readonly) |> Repo.update!()
    {:ok, view, _} = live(ctx.conn, path(ctx))

    assert has_element?(
             view,
             "#block-wrapper-#{ctx.block.id} [data-code='SELECT 40'][data-readonly='true']"
           )

    refute has_element?(view, "#discard-draft-#{ctx.block.id}")
    refute has_element?(view, "#submitted-solution-#{ctx.block.id}")
  end

  test "team discard updates both editors and refuses a teammate's queued autosave", ctx do
    team = insert(:cohort, type: :team)
    other = insert(:account)

    for user <- [ctx.user, other],
        do: insert(:cohort_membership, cohort_id: team.id, account_id: user.id)

    # Competition players resolve the team as their submission owner.
    ctx.course |> Ecto.Changeset.change(type: :competition) |> Repo.update!()
    insert(:enrollment, cohort_id: team.id, course_id: ctx.course.id)

    insert(:submission,
      account_id: other.id,
      cohort_id: team.id,
      block_id: ctx.block.id,
      status: :graded,
      score: 60,
      content: %{"type" => "code", "code" => "SELECT 60"}
    )

    Learning.save_draft(
      ctx.user,
      ctx.block.id,
      %{"type" => "code", "code" => "TEAM DRAFT"},
      team.id
    )

    other_conn = init_test_session(Phoenix.ConnTest.build_conn(), %{"account_id" => other.id})
    {:ok, alice, _} = live(ctx.conn, path(ctx))
    {:ok, bob, _} = live(other_conn, path(ctx))
    old_revision = DraftCache.revision(other.id, team.id, ctx.block.id)
    alice |> element("#discard-draft-#{ctx.block.id}") |> render_click()
    alice |> element("#discard-draft-modal button", "Delete draft") |> render_click()
    assert has_element?(bob, "#code-form-#{ctx.block.id} [data-code='']")
    refute has_element?(bob, "#discard-draft-#{ctx.block.id}")

    render_click(bob, "save_draft", %{
      "block_id" => ctx.block.id,
      "draft_revision" => old_revision,
      "answer" => %{"code" => "LATE TEAM DRAFT"}
    })

    assert Learning.get_draft(other.id, ctx.block.id, team.id) == nil
    assert has_element?(alice, "#code-form-#{ctx.block.id} [data-code='']")
  end

  test "an upload started before discard cannot recreate a deleted file draft", ctx do
    ctx.block
    |> Ecto.Changeset.change(type: :file_assignment, content: %{"max_files" => 2})
    |> Repo.update!()

    insert(:submission,
      account_id: ctx.user.id,
      block_id: ctx.block.id,
      status: :graded,
      score: 40,
      content: %{"type" => "file_assignment", "file_urls" => ["https://example.com/sent.pdf"]}
    )

    Learning.save_draft(ctx.user, ctx.block.id, %{
      "type" => "file_assignment",
      "file_urls" => ["https://example.com/draft.pdf"]
    })

    {:ok, view, _} = live(ctx.conn, path(ctx))

    render_click(view, "request_media_upload", %{
      "block_id" => ctx.block.id,
      "media_type" => "file_assignment"
    })

    view |> element("#discard-draft-#{ctx.block.id}") |> render_click()
    view |> element("#discard-draft-modal button", "Delete draft") |> render_click()

    send(view.pid, {
      AthenaWeb.StudioLive.MediaUploadComponent,
      {:saved, ctx.block.id, "file_assignment",
       [{:ok, %{"url" => "https://example.com/late.pdf"}}]}
    })

    _ = render(view)
    assert Learning.get_draft(ctx.user.id, ctx.block.id) == nil
    refute has_element?(view, "#discard-draft-#{ctx.block.id}")
  end

  defp sent(ctx, code, score, time, feedback) do
    insert(:submission,
      account_id: ctx.user.id,
      block_id: ctx.block.id,
      status: :graded,
      score: score,
      inserted_at: time,
      feedback: feedback,
      content: %{"type" => "code", "code" => code}
    )
  end

  defp path(ctx), do: ~p"/learn/courses/#{ctx.course.id}/play/#{ctx.section.id}"
end
