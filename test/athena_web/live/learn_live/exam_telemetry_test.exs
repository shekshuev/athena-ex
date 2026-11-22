defmodule AthenaWeb.LearnLive.ExamTelemetryTest do
  use AthenaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Athena.Factory

  alias Athena.Learning.Submission
  alias Athena.Repo
  alias AthenaWeb.LearnLive.ExamTelemetry

  test "batches are bounded, scoped to this paper and cannot inject server events" do
    block = %{id: Ecto.UUID.generate(), section_id: Ecto.UUID.generate()}
    socket = Phoenix.Component.assign(%Phoenix.LiveView.Socket{}, block: block, questions: [])

    event = %{
      "block_id" => block.id,
      "event_type" => "copy_attempt",
      "occurred_at" => DateTime.to_iso8601(DateTime.utc_now())
    }

    invalid = [
      nil,
      %{},
      %{event | "block_id" => Ecto.UUID.generate()},
      %{event | "event_type" => "answer_changed"},
      Map.put(event, "payload", %{"x" => String.duplicate("x", 3_000)})
    ]

    {accepted, socket} = ExamTelemetry.normalize_batch([event | invalid], socket)
    assert length(accepted) == 1
    assert {[], _} = ExamTelemetry.normalize_batch(%{}, socket)
    assert {[], _} = ExamTelemetry.normalize_batch(List.duplicate(event, 51), socket)

    socket = Phoenix.Component.assign(socket, :telemetry_budget, nil)

    socket =
      Enum.reduce(1..4, socket, fn _, socket ->
        {accepted, socket} = ExamTelemetry.normalize_batch(List.duplicate(event, 50), socket)
        assert length(accepted) == 50
        socket
      end)

    assert {[], socket} = ExamTelemetry.normalize_batch([event], socket)
    {_, used} = socket.assigns.telemetry_budget

    socket =
      Phoenix.Component.assign(
        socket,
        :telemetry_budget,
        {System.monotonic_time(:millisecond) - 11_000, used}
      )

    assert {[_], _} = ExamTelemetry.normalize_batch([event], socket)
  end

  for {kind, route} <- [{:quiz_exam, "exam"}, {:ticket_exam, "ticket"}] do
    @kind kind
    @route route
    test "#{kind}: silent monitoring and non-fullscreen layout never block answers or finish",
         %{conn: conn} do
      question_id = Ecto.UUID.generate()

      question = %{
        "id" => question_id,
        "type" => "quiz_question",
        "content" => %{
          "question_type" => "exact_match",
          "render_prompt_as_image" => true,
          "body" => %{
            "type" => "doc",
            "content" => [
              %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => "Question"}]}
            ]
          },
          "correct_answer" => "saved"
        }
      }

      {view, submission} = mount_exam(conn, @kind, @route, question)
      assert has_element?(view, "#engagement-tracker[data-heartbeat='true']")
      refute has_element?(view, "#engagement-tracker[data-fullscreen]")

      assert has_element?(
               view,
               "#editor-wrapper-play-#{question_id}[phx-hook='ClipboardTracker']"
             )

      assert has_element?(view, "#prompt-canvas-#{question_id}")
      refute has_element?(view, ".no-copy-guard")

      expire_telemetry(view)
      view |> form("##{@route}-quiz-#{question_id}", %{"answer" => "saved"}) |> render_change()
      child = Repo.get_by!(Submission, parent_submission_id: submission.id, block_id: question_id)
      assert child.content["text_answer"] == "saved"
      refute has_element?(view, "#flash-error")

      render_hook(view, "engagement_heartbeat", %{"layout" => [%{"fs" => false, "f" => false}]})
      expire_telemetry(view)
      render_click(view, "finish_exam")
      assert_redirect(view)
      assert Repo.get!(Submission, submission.id).status == :graded
    end

    test "#{kind}: silent monitoring never blocks saving code or enqueuing execution", %{
      conn: conn
    } do
      question_id = Ecto.UUID.generate()
      question = %{"id" => question_id, "type" => "code", "content" => %{"language" => "python"}}
      {view, submission} = mount_exam(conn, @kind, @route, question)
      expire_telemetry(view)

      view
      |> form("##{@route}-code-#{question_id}")
      |> render_change(%{"answer" => %{"code" => "print(42)"}})

      child = Repo.get_by!(Submission, parent_submission_id: submission.id, block_id: question_id)
      assert child.content["code"] == "print(42)"
      render_click(view, "run_code", %{"block_id" => question_id})
      assert Repo.get!(Submission, child.id).status == :processing
      refute has_element?(view, "#flash-error")
    end

    test "#{kind}: silent monitoring never blocks saving file answers", %{conn: conn} do
      question_id = Ecto.UUID.generate()
      question = %{"id" => question_id, "type" => "file_assignment", "content" => %{}}
      {view, submission} = mount_exam(conn, @kind, @route, question)
      expire_telemetry(view)

      render_hook(view, "media_upload_clipboard_success", %{
        "block_id" => question_id,
        "final_url" => "/media/answer.txt"
      })

      child = Repo.get_by!(Submission, parent_submission_id: submission.id, block_id: question_id)
      assert child.content["file_urls"] == ["/media/answer.txt"]
      refute has_element?(view, "#flash-error")
    end
  end

  defp mount_exam(conn, kind, route, question) do
    user = insert(:account)
    course = insert(:course)
    insert(:enrollment, account_id: user.id, course_id: course.id)
    section = insert(:section, course: course)
    block = insert(:block, section: section, type: kind, content: %{"require_fullscreen" => true})

    submission =
      insert(:submission,
        account_id: user.id,
        block_id: block.id,
        status: :pending,
        expires_at: DateTime.add(DateTime.utc_now(:second), 3600),
        content: %{"type" => Atom.to_string(kind), "questions" => [question]}
      )

    {:ok, view, _} =
      live(
        init_test_session(conn, %{"account_id" => user.id}),
        "/learn/courses/#{course.id}/#{route}/#{block.id}"
      )

    {view, submission}
  end

  # Simulate a page whose telemetry used to trigger the old guards.
  defp expire_telemetry(view) do
    :sys.replace_state(view.pid, fn state ->
      socket =
        Phoenix.Component.assign(state.socket,
          last_telemetry_at: DateTime.add(DateTime.utc_now(), -60),
          layout_state: %{at: DateTime.add(DateTime.utc_now(), -60), fs: false}
        )

      %{state | socket: socket}
    end)
  end
end
