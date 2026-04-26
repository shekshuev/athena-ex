defmodule AthenaWeb.LearnLive.Exam do
  use AthenaWeb, :live_view

  alias Athena.Content
  alias Athena.Learning

  @impl true
  def mount(%{"id" => course_id, "block_id" => block_id}, _session, socket) do
    user = socket.assigns.current_user

    cohort = Learning.get_user_cohort_for_course(user.id, course_id)
    team_id = if cohort && cohort.type == :team, do: cohort.id, else: nil

    socket = assign(socket, :team_id, team_id)

    with true <- Learning.has_access?(user.id, course_id),
         {:ok, _course} <- Content.get_course(course_id),
         submission when not is_nil(submission) <-
           Learning.get_submission(user.id, block_id, team_id),
         :pending <- submission.status,
         {:ok, block} <- Content.get_block(block_id),
         {:ok, socket} <- handle_active_exam(socket, course_id, block, submission) do
      {:ok, socket, layout: false}
    else
      _ ->
        socket =
          socket
          |> put_flash(:error, gettext("Exam is not active or already finished."))
          |> push_navigate(to: ~p"/learn/courses/#{course_id}")

        {:ok, socket, layout: false}
    end
  end

  @impl true
  def handle_info(:tick, socket) do
    time_left = socket.assigns.time_left - 1

    if time_left <= 0 do
      socket = submit_and_exit(socket, socket.assigns.submission, socket.assigns.course_id)
      {:noreply, socket}
    else
      {:noreply, assign(socket, :time_left, time_left)}
    end
  end

  @impl true
  def handle_event("cheat_detected", _params, socket) do
    new_count = socket.assigns.cheat_count + 1
    max_cheats = socket.assigns.max_cheats

    new_content = Map.put(socket.assigns.submission.content, "cheat_count", new_count)

    {:ok, updated_sub} =
      Learning.update_submission(socket.assigns.submission, %{"content" => new_content})

    socket = assign(socket, submission: updated_sub, cheat_count: new_count)

    if new_count >= max_cheats do
      {:ok, _failed_sub} =
        Learning.update_submission(updated_sub, %{"status" => "graded", "score" => 0})

      broadcast_team_progress(socket.assigns.team_id, socket.assigns.course_id)

      {:noreply,
       socket
       |> put_flash(:error, gettext("Exam failed due to cheating violations."))
       |> push_navigate(to: ~p"/learn/courses/#{socket.assigns.course_id}")}
    else
      {:noreply,
       put_flash(
         socket,
         :warning,
         gettext("Warning: You left the exam tab. Violation %{count} of %{max}.",
           count: new_count,
           max: max_cheats
         )
       )}
    end
  end

  @impl true
  def handle_event("save_answer", %{"answer" => answer}, socket) do
    if socket.assigns.current_question do
      q_id = socket.assigns.current_question["id"] || socket.assigns.current_question[:id]
      new_answers = Map.put(socket.assigns.answers, q_id, answer)

      new_content = Map.put(socket.assigns.submission.content, "answers", new_answers)

      {:ok, updated_sub} =
        Learning.update_submission(socket.assigns.submission, %{"content" => new_content})

      {:noreply, assign(socket, answers: new_answers, submission: updated_sub)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("save_answer", _, socket), do: {:noreply, socket}

  @impl true
  def handle_event("next_question", _, socket) do
    next_idx = min(socket.assigns.current_index + 1, max(length(socket.assigns.questions) - 1, 0))
    {:noreply, update_question(socket, next_idx)}
  end

  @impl true
  def handle_event("prev_question", _, socket) do
    prev_idx = max(socket.assigns.current_index - 1, 0)
    {:noreply, update_question(socket, prev_idx)}
  end

  @impl true
  def handle_event("jump_to", %{"index" => idx_str}, socket) do
    idx = String.to_integer(idx_str)
    {:noreply, update_question(socket, idx)}
  end

  @impl true
  def handle_event("finish_exam", _, socket) do
    socket = submit_and_exit(socket, socket.assigns.submission, socket.assigns.course_id)
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="exam-container" phx-hook="AntiCheat" class="min-h-screen bg-base-200 flex flex-col">
      <header class="bg-base-100 border-b border-base-300 p-4 sticky top-0 z-50 flex items-center justify-between shadow-sm">
        <div class="font-black text-xl flex items-center gap-2">
          <.icon name="hero-academic-cap" class="size-6 text-primary" />
          {gettext("Final Exam")}
        </div>

        <div class="flex items-center gap-6">
          <div
            :if={@max_cheats > 0}
            class={[
              "flex items-center gap-2 font-bold",
              if(@cheat_count > 0, do: "text-error", else: "text-base-content/50")
            ]}
          >
            <.icon name="hero-eye" class="size-5" />
            {gettext("Violations:")} {@cheat_count} / {@max_cheats}
          </div>

          <div
            :if={@time_limit_sec}
            class={[
              "flex items-center gap-2 font-mono text-2xl font-black px-4 py-1 rounded-lg",
              if(@time_left < 60,
                do: "bg-error text-error-content animate-pulse",
                else: "bg-base-200"
              )
            ]}
          >
            <.icon name="hero-clock" class="size-6" />
            {format_time(@time_left)}
          </div>

          <button
            phx-click="finish_exam"
            data-confirm={gettext("Are you sure you want to submit the exam?")}
            class="btn btn-error"
          >
            {gettext("Submit Exam")}
          </button>
        </div>
      </header>

      <div class="flex-1 max-w-5xl w-full mx-auto p-4 md:p-8 flex flex-col md:flex-row gap-8 items-start">
        <aside class="w-full md:w-64 shrink-0 bg-base-100 p-4 rounded-2xl border border-base-300 shadow-sm sticky top-24">
          <div class="text-xs font-bold uppercase tracking-widest text-base-content/50 mb-4 text-center">
            {gettext("Questions Navigation")}
          </div>
          <div class="flex flex-wrap gap-2 justify-center">
            <%= for {q, index} <- Enum.with_index(@questions) do %>
              <% q_id = q["id"] || q[:id] %>
              <button
                phx-click="jump_to"
                phx-value-index={index}
                class={[
                  "size-10 rounded-lg font-bold flex items-center justify-center transition-all",
                  @current_index == index && "ring-2 ring-primary ring-offset-2 ring-offset-base-100",
                  @current_index != index && "hover:bg-base-200",
                  has_answer?(@answers, q_id) && "bg-primary/10 text-primary border border-primary/30",
                  not has_answer?(@answers, q_id) && "bg-base-200 text-base-content/60"
                ]}
              >
                {index + 1}
              </button>
            <% end %>
          </div>
        </aside>

        <main class="flex-1 bg-base-100 p-6 md:p-10 rounded-2xl border border-base-300 shadow-sm w-full">
          <%= if @current_question do %>
            <% q_id = @current_question["id"] || @current_question[:id] %>
            <% q_type = to_string(@current_question["type"] || @current_question[:type]) %>
            <% q_body = @current_question["question"] || @current_question[:question] || %{} %>
            <% q_options = @current_question["options"] || @current_question[:options] || [] %>

            <div class="flex items-center gap-3 mb-6 pb-6 border-b border-base-200">
              <div class="size-10 bg-primary text-primary-content font-black rounded-xl flex items-center justify-center text-xl">
                {@current_index + 1}
              </div>
              <h2 class="text-xl font-bold text-base-content/50 uppercase tracking-widest">
                {gettext("Question")}
              </h2>
            </div>

            <div
              id={"question-tiptap-#{q_id}"}
              phx-hook="TiptapEditor"
              data-id={q_id}
              data-readonly="true"
              phx-update="ignore"
              data-content={Jason.encode!(q_body)}
              class="prose prose-lg max-w-none mb-10 text-base-content/80"
            >
            </div>

            <form phx-change="save_answer" phx-submit="next_question">
              <%= case q_type do %>
                <% "exact_match" -> %>
                  <input
                    type="text"
                    name="answer"
                    value={@answers[q_id]}
                    placeholder={gettext("Type your answer...")}
                    class="input input-bordered input-lg w-full font-mono"
                    phx-debounce="500"
                  />
                <% "open" -> %>
                  <textarea
                    name="answer"
                    rows="6"
                    placeholder={gettext("Write your essay here...")}
                    class="textarea textarea-bordered w-full text-lg leading-relaxed"
                    phx-debounce="1000"
                  ><%= @answers[q_id] %></textarea>
                <% "single" -> %>
                  <div class="space-y-3">
                    <%= for opt <- q_options do %>
                      <% opt_id = opt["id"] || opt[:id] %>
                      <% opt_text = opt["text"] || opt[:text] %>
                      <label class="flex items-start gap-4 p-4 rounded-xl border border-base-200 hover:bg-base-200/50 cursor-pointer has-checked:bg-primary/5 has-checked:border-primary transition-all">
                        <input
                          type="radio"
                          name="answer"
                          value={opt_id}
                          checked={@answers[q_id] == opt_id}
                          class="radio radio-primary mt-1"
                        />
                        <span class="text-lg font-medium">{opt_text}</span>
                      </label>
                    <% end %>
                  </div>
                <% "multiple" -> %>
                  <div class="space-y-3">
                    <%= for opt <- q_options do %>
                      <% opt_id = opt["id"] || opt[:id] %>
                      <% opt_text = opt["text"] || opt[:text] %>
                      <label class="flex items-start gap-4 p-4 rounded-xl border border-base-200 hover:bg-base-200/50 cursor-pointer has-checked:bg-primary/5 has-checked:border-primary transition-all">
                        <input
                          type="checkbox"
                          name="answer[]"
                          value={opt_id}
                          checked={opt_id in List.wrap(@answers[q_id])}
                          class="checkbox checkbox-primary mt-1"
                        />
                        <span class="text-lg font-medium">{opt_text}</span>
                      </label>
                    <% end %>
                  </div>
                <% _ -> %>
                  <div class="p-4 text-warning bg-warning/10 rounded-lg">
                    {gettext("Unknown question type:")} {q_type}
                  </div>
              <% end %>

              <div class="flex items-center justify-between mt-12 pt-6 border-t border-base-200">
                <button
                  type="button"
                  phx-click="prev_question"
                  class="btn btn-outline"
                  disabled={@current_index == 0}
                >
                  <.icon name="hero-arrow-left" class="size-5 mr-2" /> {gettext("Previous")}
                </button>

                <%= if @current_index >= length(@questions) - 1 do %>
                  <button type="button" phx-click="finish_exam" class="btn btn-primary px-8">
                    {gettext("Finish & Submit")} <.icon name="hero-check" class="size-5 ml-2" />
                  </button>
                <% else %>
                  <button type="submit" class="btn btn-primary px-8">
                    {gettext("Next")} <.icon name="hero-arrow-right" class="size-5 ml-2" />
                  </button>
                <% end %>
              </div>
            </form>
          <% else %>
            <div class="p-10 text-center">
              <.icon name="hero-exclamation-circle" class="size-12 text-base-content/30 mx-auto mb-4" />
              <h3 class="text-xl font-bold text-base-content/50">
                {gettext("No questions available")}
              </h3>
              <p class="text-base-content/40 mt-2">{gettext("Please contact your instructor.")}</p>
              <button type="button" phx-click="finish_exam" class="btn btn-primary mt-6">
                {gettext("Return to Course")}
              </button>
            </div>
          <% end %>
        </main>
      </div>
    </div>
    """
  end

  defp update_question(socket, index) do
    socket
    |> assign(:current_index, index)
    |> assign(:current_question, Enum.at(socket.assigns.questions, index))
  end

  defp submit_and_exit(socket, submission, course_id) do
    {:ok, _} = Learning.update_submission(submission, %{"status" => "needs_review", "score" => 0})

    broadcast_team_progress(socket.assigns.team_id, course_id)

    socket
    |> put_flash(:success, gettext("Exam submitted successfully!"))
    |> push_navigate(to: ~p"/learn/courses/#{course_id}")
  end

  defp has_answer?(answers, q_id) do
    case Map.get(answers, q_id) do
      nil -> false
      "" -> false
      [] -> false
      _ -> true
    end
  end

  defp format_time(seconds) do
    m = div(seconds, 60)
    s = rem(seconds, 60)

    "#{String.pad_leading(Integer.to_string(m), 2, "0")}:#{String.pad_leading(Integer.to_string(s), 2, "0")}"
  end

  defp parse_dt(%DateTime{} = dt), do: dt

  defp parse_dt(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end

  defp handle_active_exam(socket, course_id, block, submission) do
    time_limit_sec = calc_time_limit_sec(block.content["time_limit"])
    time_left = calc_time_left(time_limit_sec, submission.content["started_at"])
    mount_exam_state(socket, course_id, block, submission, time_limit_sec, time_left)
  end

  defp mount_exam_state(socket, course_id, _block, submission, limit_sec, time_left)
       when not is_nil(limit_sec) and time_left <= 0 do
    {:ok, submit_and_exit(socket, submission, course_id)}
  end

  defp mount_exam_state(socket, course_id, block, submission, time_limit_sec, time_left) do
    maybe_start_timer(socket, time_limit_sec)

    {:ok, assign_exam_state(socket, course_id, block, submission, time_limit_sec, time_left)}
  end

  defp maybe_start_timer(socket, time_limit_sec) do
    if connected?(socket) and not is_nil(time_limit_sec) do
      :timer.send_interval(1000, self(), :tick)
    end
  end

  defp assign_exam_state(socket, course_id, block, submission, time_limit_sec, time_left) do
    content = submission.content
    questions = Map.get(content, "questions", [])

    socket
    |> assign(:course_id, course_id)
    |> assign(:block, block)
    |> assign(:submission, submission)
    |> assign(:questions, questions)
    |> assign(:current_index, 0)
    |> assign(:current_question, Enum.at(questions, 0))
    |> assign(:answers, Map.get(content, "answers", %{}))
    |> assign(:time_limit_sec, time_limit_sec)
    |> assign(:time_left, time_left)
    |> assign(:cheat_count, Map.get(content, "cheat_count", 0))
    |> assign(:max_cheats, Map.get(block.content, "allowed_blur_attempts", 3))
  end

  defp calc_time_limit_sec(nil), do: nil
  defp calc_time_limit_sec(minutes), do: minutes * 60

  defp calc_time_left(nil, _started_at), do: nil

  defp calc_time_left(limit_sec, started_at) do
    time_passed = DateTime.diff(DateTime.utc_now(), parse_dt(started_at))
    max(limit_sec - time_passed, 0)
  end

  defp broadcast_team_progress(nil, _course_id), do: :ok

  defp broadcast_team_progress(team_id, course_id) do
    Phoenix.PubSub.broadcast(Athena.PubSub, "team_progress:#{team_id}", :team_progress_updated)
    Phoenix.PubSub.broadcast(Athena.PubSub, "leaderboard:#{course_id}", :update_leaderboard)
  end
end
