defmodule AthenaWeb.TestRunComponents do
  @moduledoc """
  The full-screen "Test run" modal shared by the course builder (play a
  section) and the library block page (play a single block).

  Both host LiveViews keep the `Athena.Learning.TestRunSession` and the
  active exam in their own assigns, and swap the nested `Player` for the exam
  LiveViews when the player sends `{:test_run_enter_exam, ...}`.
  """
  use AthenaWeb, :html

  attr :socket, :any, required: true
  attr :session, :map, required: true
  attr :active_exam, :map, default: nil

  def test_run_modal(assigns) do
    ~H"""
    <div id="test-run-modal" class="fixed inset-0 z-60 flex flex-col bg-base-200">
      <div class="flex items-center gap-3 px-4 py-3 bg-base-100 border-b border-base-300 shrink-0">
        <.icon name="hero-play-circle" class="size-5 text-primary" />
        <span class="font-bold">{gettext("Test run")}</span>
        <span class="text-sm text-base-content/60">
          {gettext(
            "Playing as a throwaway test student. Scheduling (unlock/lock dates) is ignored; nothing here is saved once you close this window."
          )}
        </span>
        <button
          type="button"
          phx-click="close_test_run"
          class="btn btn-sm btn-ghost ml-auto"
        >
          <.icon name="hero-x-mark" class="size-4" />
          {gettext("Close")}
        </button>
      </div>
      <div class="flex-1 overflow-y-auto">
        <%= if @active_exam do %>
          <% exam_module =
            if @active_exam.block_type == :ticket_exam,
              do: AthenaWeb.LearnLive.TicketExam,
              else: AthenaWeb.LearnLive.Exam %>
          {live_render(@socket, exam_module,
            id: "test-run-exam-#{@session.id}-#{@active_exam.block_id}",
            session: %{
              "test_run_id" => @session.id,
              "block_id" => @active_exam.block_id
            }
          )}
        <% else %>
          {live_render(@socket, AthenaWeb.LearnLive.Player,
            id: "test-run-player-#{@session.id}",
            session: %{"test_run_id" => @session.id}
          )}
        <% end %>
      </div>
    </div>
    """
  end
end
