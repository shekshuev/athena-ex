defmodule AthenaWeb.LearnLive.EngagementSignals do
  @moduledoc """
  Server-originated engagement events - the ones the *server* records on the
  student's behalf (as opposed to the client-batched events relayed through
  `"engagement_batch"`): `answer_selected`/`answer_changed`/quiz
  `first_interaction`, `code_run_attempt`, `code_run_result`.

  Extracted from `AthenaWeb.LearnLive.Player` (where this logic originated)
  so it can be shared verbatim by every LiveView that renders exam
  sub-questions via the same `content_block/1` component -
  `AthenaWeb.LearnLive.Exam` and `AthenaWeb.LearnLive.TicketExam` need the
  exact same signals `Player` already produces, not a re-implementation of
  them. Before this module existed, these signals were private functions
  inside `Player` and simply never fired during an exam attempt.

  Every function here reads `section_id` and `test_run?` off the socket with
  a fallback chain (`:section` assign, else the current `:block`'s own
  `section_id`; `:test_run` assign, else `false`) so callers never need to
  pass them explicitly - `Player` has a `:section` assign, the exam
  LiveViews only have `:block`.
  """

  import Phoenix.Component, only: [assign: 3]

  alias Athena.Engagement

  @doc """
  `answer_selected`/`answer_changed` were part of the event catalog from the
  start but never actually wired client-side - rather than a dedicated JS
  hook on every radio/checkbox/rich-text input, this reuses whatever
  autosave already fires on every quiz interaction (single/multiple/
  exact_match and the open rich-text answer all go through one). First save
  for this block this session doubles as TTFA's `first_interaction`; every
  save after that is a revision. Requires an `:engagement_answered_blocks`
  `MapSet` assign on the caller's socket.
  """
  @spec record_quiz_interaction(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def record_quiz_interaction(socket, %{type: :quiz_question, id: block_id}) do
    answered = socket.assigns.engagement_answered_blocks

    if MapSet.member?(answered, block_id) do
      emit_engagement_event(socket, block_id, :answer_changed)
    else
      socket
      |> emit_engagement_events(block_id, [:first_interaction, :answer_selected])
      |> assign(:engagement_answered_blocks, MapSet.put(answered, block_id))
    end
  end

  def record_quiz_interaction(socket, _block), do: socket

  @doc "Recorded the moment a student clicks \"Run\", before the outcome is known."
  @spec emit_code_run_attempt(Phoenix.LiveView.Socket.t(), binary()) ::
          Phoenix.LiveView.Socket.t()
  def emit_code_run_attempt(socket, block_id) do
    emit_engagement_event(socket, block_id, :code_run_attempt)
  end

  @doc "Recorded once an async code execution settles, mirroring the resulting `Submission.status` into the event timeline."
  @spec emit_code_run_result(Phoenix.LiveView.Socket.t(), binary(), atom() | String.t()) ::
          Phoenix.LiveView.Socket.t()
  def emit_code_run_result(socket, block_id, outcome) do
    emit_engagement_event(socket, block_id, :code_run_result, %{"outcome" => to_string(outcome)})
  end

  @doc "One server-originated event, immediately recorded (unless this is a Builder test run)."
  @spec emit_engagement_event(Phoenix.LiveView.Socket.t(), binary(), atom(), map()) ::
          Phoenix.LiveView.Socket.t()
  def emit_engagement_event(socket, block_id, event_type, payload \\ %{}) do
    unless test_run?(socket) do
      Engagement.record_events(
        socket.assigns.current_user.id,
        socket.assigns.cohort_id,
        socket.assigns.engagement_session_id,
        [
          %{
            block_id: block_id,
            section_id: section_id(socket),
            event_type: event_type,
            payload: payload,
            occurred_at: DateTime.utc_now() |> DateTime.truncate(:second)
          }
        ]
      )

      maybe_forward_to_proctoring(socket, [%{event_type: event_type, payload: payload}])
    end

    socket
  end

  @doc """
  Same as `emit_engagement_event/4` but for several event types that
  genuinely happen at the same instant (`first_interaction` +
  `answer_selected` on a quiz's very first answer) - one batch, one
  timestamp, instead of two separate round trips.
  """
  @spec emit_engagement_events(Phoenix.LiveView.Socket.t(), binary(), [atom()]) ::
          Phoenix.LiveView.Socket.t()
  def emit_engagement_events(socket, block_id, event_types) do
    unless test_run?(socket) do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      section_id = section_id(socket)

      events =
        Enum.map(event_types, fn event_type ->
          %{
            block_id: block_id,
            section_id: section_id,
            event_type: event_type,
            payload: %{},
            occurred_at: now
          }
        end)

      Engagement.record_events(
        socket.assigns.current_user.id,
        socket.assigns.cohort_id,
        socket.assigns.engagement_session_id,
        events
      )

      maybe_forward_to_proctoring(socket, events)
    end

    socket
  end

  # The exam LiveViews are the only callers with a singular `:submission`
  # assign (the parent exam attempt) - `Player` has a `:submissions` map
  # keyed by block id instead, so this is naturally a no-op there. Only
  # forwards event types `Athena.Engagement.ProctoringMonitor` actually
  # accumulates (`:answer_changed`, `:code_run_attempt` - the only two of
  # this module's event types on that list), so this never wakes a
  # proctoring process for e.g. `:first_interaction`/`:nudge_shown`.
  defp maybe_forward_to_proctoring(socket, events) do
    with %{id: submission_id} <- socket.assigns[:submission],
         %{id: exam_block_id} <- socket.assigns[:block] do
      events
      |> Enum.filter(&(&1.event_type in Engagement.proctoring_tracked_event_types()))
      |> case do
        [] ->
          :ok

        proctoring_events ->
          Engagement.report_proctoring_events(
            submission_id,
            socket.assigns[:cohort_id],
            exam_block_id,
            proctoring_events
          )
      end
    else
      _ -> :ok
    end
  end

  defp section_id(socket) do
    case socket.assigns[:section] do
      %{id: id} -> id
      _ -> socket.assigns.block.section_id
    end
  end

  defp test_run?(socket), do: !!socket.assigns[:test_run]
end
