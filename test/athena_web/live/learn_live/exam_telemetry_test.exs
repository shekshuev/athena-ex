defmodule AthenaWeb.LearnLive.ExamTelemetryTest do
  use AthenaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Athena.Factory
  import Ecto.Query

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
    test "#{kind}: stale telemetry blocks answers, code execution and finish; heartbeat restores saves",
         %{conn: conn} do
      user = insert(:account)
      course = insert(:course)
      insert(:enrollment, account_id: user.id, course_id: course.id)
      section = insert(:section, course: course)
      block = insert(:block, section: section, type: @kind)
      question_id = Ecto.UUID.generate()

      question = %{
        "id" => question_id,
        "type" => "quiz_question",
        "content" => %{"question_type" => "exact_match", "body" => %{"text" => "Question"}}
      }

      submission =
        insert(:submission,
          account_id: user.id,
          block_id: block.id,
          status: :pending,
          expires_at: DateTime.add(DateTime.utc_now(:second), 3600),
          content: %{"type" => Atom.to_string(@kind), "questions" => [question]}
        )

      {:ok, view, _} =
        live(
          init_test_session(conn, %{"account_id" => user.id}),
          "/learn/courses/#{course.id}/#{@route}/#{block.id}"
        )

      assert has_element?(view, "#engagement-tracker")
      expire_telemetry(view)
      render_click(view, "save_answer", %{"answer" => "blocked"})
      render_click(view, "run_code", %{"block_id" => question_id})
      render_click(view, "finish_exam")
      assert Repo.get!(Submission, submission.id).status == :pending
      refute Repo.exists?(from(s in Submission, where: s.parent_submission_id == ^submission.id))
      # Empty or invalid batches cannot refresh the gate.
      render_hook(view, "engagement_batch", %{"events" => []})
      render_click(view, "save_answer", %{"answer" => "still blocked"})
      refute Repo.exists?(from(s in Submission, where: s.parent_submission_id == ^submission.id))
      render_hook(view, "engagement_heartbeat", %{})
      render_click(view, "save_answer", %{"answer" => "saved"})
      assert Repo.exists?(from(s in Submission, where: s.parent_submission_id == ^submission.id))
    end
  end

  defp expire_telemetry(view) do
    :sys.replace_state(view.pid, fn state ->
      socket =
        Phoenix.Component.assign(
          state.socket,
          :last_telemetry_at,
          DateTime.add(DateTime.utc_now(), -60)
        )

      %{state | socket: socket}
    end)
  end
end
