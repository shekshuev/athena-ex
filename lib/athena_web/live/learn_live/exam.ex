defmodule AthenaWeb.LearnLive.Exam do
  @moduledoc """
  Student Exam LiveView.

  Features:
  - Hierarchical submissions (parent exam + child question submissions).
  - Strict server-side time limit enforcement.
  - Universal block rendering via BlockComponents.content_block/1.
  - Full media upload support mirroring the Player experience.
  """
  use AthenaWeb, :live_view

  alias Athena.{Content, Learning}
  import AthenaWeb.BlockComponents

  @impl true
  def mount(%{"id" => course_id, "block_id" => block_id} = params, _session, socket) do
    user = socket.assigns.current_user
    cohort = Learning.get_user_cohort_for_course(user.id, course_id)
    team_id = if cohort && cohort.type == :team, do: cohort.id, else: nil

    return_to = Map.get(params, "return_to", ~p"/learn/courses/#{course_id}/play")

    with {:ok, block} <- Content.get_block(block_id),
         time_limit_sec <- get_time_limit_sec(block),
         {:ok, submission} <-
           Learning.get_or_create_exam_attempt(
             user.id,
             block_id,
             team_id,
             time_limit_sec,
             block.content
           ) do
      if DateTime.compare(DateTime.utc_now(), submission.expires_at) == :gt do
        socket = submit_and_exit(socket, submission, course_id, :time_limit_exceeded)
        {:ok, socket}
      else
        questions = hydrate_questions(submission.content["questions"] || [])
        child_subs = Learning.get_child_submissions(submission.id)

        pending_urls =
          child_subs
          |> Enum.reduce(%{}, fn {q_id, sub}, acc ->
            content = sub.content || %{}

            if content["type"] in ["file_assignment", :file_assignment] do
              Map.put(acc, q_id, content["file_urls"] || [])
            else
              acc
            end
          end)

        socket =
          socket
          |> assign(:course_id, course_id)
          |> assign(:team_id, team_id)
          |> assign(:block, block)
          |> assign(:submission, submission)
          |> assign(:questions, questions)
          |> assign(:current_index, 0)
          |> assign(:current_question, Enum.at(questions, 0))
          |> assign(:child_submissions, child_subs)
          |> assign(:time_limit_sec, time_limit_sec)
          |> assign(:time_left, DateTime.diff(submission.expires_at, DateTime.utc_now()))
          |> assign(:pending_file_urls, pending_urls)
          |> assign(:show_media_modal, false)
          |> assign(:show_finish_modal, false)
          |> assign(:return_to, return_to)
          |> assign(:active_upload_block_id, nil)
          |> assign(:upload_type, nil)
          |> assign(:max_files_for_upload, 1)
          |> assign(:current_file_count_for_upload, 0)

        if connected?(socket) do
          for q <- questions do
            Phoenix.PubSub.subscribe(Athena.PubSub, "submission:#{user.id}:#{q.id}")
          end
        end

        maybe_start_timer(socket)
        {:ok, socket}
      end
    else
      _ ->
        socket =
          socket
          |> put_flash(:error, gettext("Exam is not active or already finished."))
          |> push_navigate(to: ~p"/learn/courses/#{course_id}")

        {:ok, socket}
    end
  end

  @impl true
  def handle_event("save_answer", params, socket) do
    process_exam_answer(params, socket)
  end

  def handle_event("save_draft", params, socket) do
    process_exam_answer(params, socket)
  end

  def handle_event("submit_quiz", params, socket) do
    process_exam_answer(params, socket)
    handle_event("next_question", %{}, socket)
  end

  def handle_event("submit_code", params, socket) do
    process_exam_answer(params, socket)
    {:noreply, put_flash(socket, :info, gettext("Code saved."))}
  end

  def handle_event(
        "request_media_upload",
        %{"block_id" => block_id, "media_type" => "file_assignment"},
        socket
      ) do
    case check_time_limit(socket) do
      {:halt, socket} ->
        {:noreply, socket}

      {:ok, socket} ->
        block = Enum.find(socket.assigns.questions, &(&1.id == block_id))

        if block && to_string(block.type) == "file_assignment" do
          max_files = block.content["max_files"] || 1
          pending = socket.assigns.pending_file_urls || %{}
          current_count = length(Map.get(pending, block_id, []))

          {:noreply,
           socket
           |> assign(:show_media_modal, true)
           |> assign(:active_upload_block_id, block_id)
           |> assign(:upload_type, "file_assignment")
           |> assign(:max_files_for_upload, max_files)
           |> assign(:current_file_count_for_upload, current_count)}
        else
          {:noreply, put_flash(socket, :error, gettext("Invalid block for file upload."))}
        end
    end
  end

  def handle_event("cancel_media_upload", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_media_modal, false)
     |> assign(:active_upload_block_id, nil)
     |> assign(:upload_type, nil)}
  end

  def handle_event(
        "media_upload_clipboard_success",
        %{"block_id" => block_id, "final_url" => url},
        socket
      ) do
    pending = socket.assigns.pending_file_urls || %{}
    current_urls = Map.get(pending, block_id, [])

    block = Enum.find(socket.assigns.questions, &(&1.id == block_id))
    max_files = if block, do: block.content["max_files"] || 1, else: 1

    if length(current_urls) < max_files do
      updated_urls = current_urls ++ [url]
      updated_pending = Map.put(pending, block_id, updated_urls)

      socket = save_exam_file_assignment(socket, block_id, updated_urls)

      {:noreply, assign(socket, :pending_file_urls, updated_pending)}
    else
      {:noreply, put_flash(socket, :error, gettext("Maximum number of files reached."))}
    end
  end

  def handle_event(
        "remove_pending_file",
        %{"block_id" => block_id, "url" => url},
        socket
      ) do
    pending = socket.assigns.pending_file_urls || %{}
    current = Map.get(pending, block_id, [])
    updated = List.delete(current, url)
    updated_pending = Map.put(pending, block_id, updated)

    socket = save_exam_file_assignment(socket, block_id, updated)

    {:noreply, assign(socket, :pending_file_urls, updated_pending)}
  end

  def handle_event("submit_file_assignment", %{"block_id" => block_id}, socket) do
    pending = socket.assigns.pending_file_urls || %{}
    file_urls = Map.get(pending, block_id, []) |> Enum.reject(&(&1 == ""))

    if file_urls == [] do
      {:noreply, put_flash(socket, :error, gettext("Please upload at least one file."))}
    else
      socket =
        if Map.has_key?(socket.assigns.child_submissions, block_id) do
          socket
        else
          save_exam_file_assignment(socket, block_id, file_urls)
        end

      child_sub = Map.get(socket.assigns.child_submissions, block_id)

      if child_sub do
        {:ok, updated_sub} =
          Learning.system_update_submission(child_sub, %{"status" => "pending"})

        new_child_subs = Map.put(socket.assigns.child_submissions, block_id, updated_sub)

        {:noreply,
         socket
         |> assign(:child_submissions, new_child_subs)
         |> put_flash(:info, gettext("Files submitted successfully!"))}
      else
        {:noreply, put_flash(socket, :error, gettext("Error submitting assignment."))}
      end
    end
  end

  def handle_event("next_question", _, socket) do
    case check_time_limit(socket) do
      {:halt, socket} ->
        {:noreply, socket}

      {:ok, socket} ->
        next_idx =
          min(socket.assigns.current_index + 1, max(length(socket.assigns.questions) - 1, 0))

        {:noreply, update_question(socket, next_idx)}
    end
  end

  def handle_event("prev_question", _, socket) do
    case check_time_limit(socket) do
      {:halt, socket} ->
        {:noreply, socket}

      {:ok, socket} ->
        prev_idx = max(socket.assigns.current_index - 1, 0)
        {:noreply, update_question(socket, prev_idx)}
    end
  end

  def handle_event("jump_to", %{"index" => idx_str}, socket) do
    case check_time_limit(socket) do
      {:halt, socket} ->
        {:noreply, socket}

      {:ok, socket} ->
        idx = String.to_integer(idx_str)
        {:noreply, update_question(socket, idx)}
    end
  end

  def handle_event("open_finish_modal", _, socket) do
    {:noreply, assign(socket, show_finish_modal: true)}
  end

  def handle_event("close_finish_modal", _, socket) do
    {:noreply, assign(socket, show_finish_modal: false)}
  end

  def handle_event("finish_exam", _, socket) do
    case check_time_limit(socket) do
      {:halt, socket} ->
        {:noreply, socket}

      {:ok, socket} ->
        socket =
          submit_and_exit(socket, socket.assigns.submission, socket.assigns.course_id, :finished)

        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("run_code", %{"block_id" => block_id}, socket) do
    case check_time_limit(socket) do
      {:halt, socket} ->
        {:noreply, socket}

      {:ok, socket} ->
        child_sub = Map.get(socket.assigns.child_submissions, block_id)

        submission_to_run =
          if child_sub do
            child_sub
          else
            answer_content = %{"type" => :code, "code" => ""}

            case Learning.save_question_submission(
                   socket.assigns.submission,
                   socket.assigns.current_user.id,
                   block_id,
                   socket.assigns.team_id,
                   answer_content
                 ) do
              {:ok, new_sub} -> new_sub
              {:error, _} -> nil
            end
          end

        if submission_to_run do
          case Learning.enqueue_code_execution(submission_to_run) do
            {:ok, processing_sub} ->
              new_child_subs = Map.put(socket.assigns.child_submissions, block_id, processing_sub)
              {:noreply, assign(socket, :child_submissions, new_child_subs)}

            {:error, err} ->
              dbg(err)
              {:noreply, put_flash(socket, :error, gettext("Failed to start code execution."))}
          end
        else
          {:noreply, socket}
        end
    end
  end

  @impl true
  def handle_info(
        {AthenaWeb.StudioLive.MediaUploadComponent,
         {:saved, _msg_block_id, "file_assignment", results}},
        socket
      ) do
    {successes, errors} =
      Enum.split_with(results, fn
        {:ok, _} -> true
        _ -> false
      end)

    file_urls =
      successes
      |> Enum.map(fn {:ok, file_map} -> file_map["url"] end)
      |> Enum.reject(&is_nil/1)

    block_id = socket.assigns.active_upload_block_id

    pending = socket.assigns.pending_file_urls || %{}
    current = Map.get(pending, block_id, [])
    updated_pending = Map.put(pending, block_id, current ++ file_urls)

    socket = save_exam_file_assignment(socket, block_id, updated_pending[block_id])

    socket =
      socket
      |> assign(:pending_file_urls, updated_pending)
      |> assign(:show_media_modal, false)
      |> assign(:active_upload_block_id, nil)
      |> assign(:upload_type, nil)

    socket =
      if errors != [] do
        error_count = length(errors)

        put_flash(
          socket,
          :error,
          gettext("Failed to save %{count} file(s)", count: error_count)
        )
      else
        put_flash(socket, :info, gettext("File(s) ready to submit"))
      end

    {:noreply, socket}
  end

  def handle_info(:tick, socket) do
    time_left = DateTime.diff(socket.assigns.submission.expires_at, DateTime.utc_now())

    if time_left <= 0 do
      {:noreply,
       submit_and_exit(
         socket,
         socket.assigns.submission,
         socket.assigns.course_id,
         :time_limit_exceeded
       )}
    else
      socket = assign(socket, :time_left, time_left)

      Process.send_after(self(), :tick, 1000)

      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:submission_updated, updated_sub}, socket) do
    new_child_subs = Map.put(socket.assigns.child_submissions, updated_sub.block_id, updated_sub)

    flash_msg =
      case updated_sub.status do
        :accepted -> gettext("Success! Code passed all tests.")
        :rejected -> gettext("Execution failed. Check the details below.")
        _ -> nil
      end

    socket = if flash_msg, do: put_flash(socket, :info, flash_msg), else: socket

    {:noreply, assign(socket, :child_submissions, new_child_subs)}
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="exam-container" class="flex flex-col min-h-screen">
      <header class="bg-base-100 border-b border-base-300 sticky top-0 z-50">
        <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8">
          <div class="flex items-center justify-between h-16">
            <div class="flex items-center gap-3">
              <.icon name="hero-academic-cap" class="size-6 text-primary" />
              <h1 class="font-display font-black text-lg uppercase tracking-tight">
                {gettext("Assessment Session")}
              </h1>
            </div>

            <div class="flex items-center gap-4">
              <div
                :if={@time_limit_sec}
                class={[
                  "flex items-center gap-2 font-mono text-lg font-bold px-3 py-1 rounded-sm border",
                  if(@time_left < 60,
                    do: "bg-error/10 border-error text-error animate-pulse",
                    else: "bg-base-200 border-base-300 text-base-content"
                  )
                ]}
              >
                <.icon name="hero-clock" class="size-4" />
                {format_time(@time_left)}
              </div>

              <button
                phx-click="open_finish_modal"
                class="btn btn-error btn-sm"
              >
                {gettext("Submit")}
              </button>
            </div>
          </div>
        </div>

        <div class="border-t border-base-300 bg-base-200/50">
          <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-3">
            <div class="flex items-center gap-2 overflow-x-auto pb-1">
              <%= for {q, index} <- Enum.with_index(@questions) do %>
                <button
                  phx-click="jump_to"
                  phx-value-index={index}
                  class={[
                    "size-9 rounded-sm font-bold text-sm flex items-center justify-center transition-all shrink-0 border",
                    @current_index == index && "bg-primary text-primary-content border-primary",
                    @current_index != index && Map.has_key?(@child_submissions, q.id) &&
                      "bg-success/10 text-success border-success/30 hover:bg-success/20",
                    @current_index != index && not Map.has_key?(@child_submissions, q.id) &&
                      "bg-base-100 text-base-content/60 border-base-300 hover:bg-base-200 hover:border-base-content/20"
                  ]}
                  title={gettext("Question %{num}", num: index + 1)}
                >
                  {index + 1}
                </button>
              <% end %>
            </div>
          </div>
        </div>
      </header>

      <main class="flex-1 bg-base-200 py-8 px-4 sm:px-6 lg:px-8">
        <div class="max-w-4xl mx-auto">
          <%= if @current_question do %>
            <div class="bg-base-100 border border-base-300 rounded-sm">
              <div class="flex items-center gap-3 p-6 border-b border-base-300">
                <div class="size-10 bg-primary text-primary-content font-black rounded-sm flex items-center justify-center text-lg">
                  {@current_index + 1}
                </div>
                <div class="flex-1">
                  <h2 class="text-sm font-bold text-base-content/50 uppercase tracking-wider">
                    {gettext("Question")}
                  </h2>
                  <p class="text-xs text-base-content/40 mt-0.5">
                    {gettext("%{current} of %{total}",
                      current: @current_index + 1,
                      total: length(@questions)
                    )}
                  </p>
                </div>
              </div>

              <div class="p-6">
                <%= case @current_question.type do %>
                  <% :quiz_question -> %>
                    <form
                      phx-change="save_answer"
                      phx-submit="submit_quiz"
                      id={"exam-quiz-#{@current_question.id}"}
                    >
                      <input type="hidden" name="block_id" value={@current_question.id} />
                      <.content_block
                        block={@current_question}
                        mode={:play}
                        submission={Map.get(@child_submissions, @current_question.id)}
                        pending_file_urls={@pending_file_urls}
                      />
                    </form>
                  <% :code -> %>
                    <form
                      phx-change="save_answer"
                      phx-submit="submit_code"
                      id={"exam-code-#{@current_question.id}"}
                    >
                      <input type="hidden" name="block_id" value={@current_question.id} />
                      <.content_block
                        block={@current_question}
                        mode={:play}
                        submission={Map.get(@child_submissions, @current_question.id)}
                        pending_file_urls={@pending_file_urls}
                        hide_submit={true}
                      />
                    </form>
                  <% :file_assignment -> %>
                    <form
                      phx-change="save_answer"
                      phx-submit="submit_file_assignment"
                      id={"exam-file-#{@current_question.id}"}
                    >
                      <input type="hidden" name="block_id" value={@current_question.id} />
                      <.content_block
                        block={@current_question}
                        mode={:play}
                        submission={Map.get(@child_submissions, @current_question.id)}
                        pending_file_urls={@pending_file_urls}
                      />
                    </form>
                  <% _ -> %>
                    <.content_block
                      block={@current_question}
                      mode={:play}
                      submission={Map.get(@child_submissions, @current_question.id)}
                      pending_file_urls={@pending_file_urls}
                    />
                <% end %>
              </div>

              <div class="flex items-center justify-between p-6 border-t border-base-300 bg-base-200/30">
                <button
                  type="button"
                  phx-click="prev_question"
                  class="btn btn-outline btn-sm"
                  disabled={@current_index == 0}
                >
                  <.icon name="hero-arrow-left" class="size-4 mr-1" /> {gettext("Previous")}
                </button>

                <% all_answered = all_questions_answered?(@questions, @child_submissions) %>

                <%= if @current_index >= length(@questions) - 1 and all_answered do %>
                  <button type="button" phx-click="open_finish_modal" class="btn btn-primary btn-sm">
                    {gettext("Finish & Submit")} <.icon name="hero-check" class="size-4 ml-1" />
                  </button>
                <% else %>
                  <button type="button" phx-click="next_question" class="btn btn-primary btn-sm">
                    {gettext("Next")} <.icon name="hero-arrow-right" class="size-4 ml-1" />
                  </button>
                <% end %>
              </div>
            </div>
          <% else %>
            <div class="bg-base-100 border border-base-300 rounded-sm p-12 text-center">
              <.icon name="hero-exclamation-circle" class="size-16 text-base-content/20 mx-auto mb-6" />
              <h3 class="text-xl font-bold text-base-content/60 mb-2">
                {gettext("No questions available")}
              </h3>
              <p class="text-base-content/40 mb-6">{gettext("Please contact your instructor.")}</p>
              <button type="button" phx-click="open_finish_modal" class="btn btn-primary">
                {gettext("Return to Course")}
              </button>
            </div>
          <% end %>
        </div>
      </main>

      <%= if @show_media_modal do %>
        <.live_component
          module={AthenaWeb.StudioLive.MediaUploadComponent}
          id={"media-uploader-exam-#{@active_upload_block_id}"}
          block_id={@active_upload_block_id}
          upload_type={@upload_type}
          current_user={@current_user}
          course_id={@course_id}
          context="student_submission"
          max_files={@max_files_for_upload}
          current_file_count={@current_file_count_for_upload}
        />
      <% end %>

      <.modal
        :if={@show_finish_modal}
        id="finish-exam-modal"
        show={true}
        title={gettext("Submit Exam?")}
        description={
          gettext(
            "Are you sure you want to finish? You won't be able to change your answers after submission."
          )
        }
        confirm_label={gettext("Yes, Submit Exam")}
        on_cancel={JS.push("close_finish_modal")}
        on_confirm={JS.push("finish_exam")}
      />
    </div>
    """
  end

  defp check_time_limit(socket) do
    expires_at = socket.assigns.submission.expires_at

    if DateTime.compare(DateTime.utc_now(), expires_at) == :gt do
      {:halt,
       submit_and_exit(
         socket,
         socket.assigns.submission,
         socket.assigns.course_id,
         :time_limit_exceeded
       )}
    else
      {:ok, socket}
    end
  end

  defp process_exam_answer(params, socket) do
    case check_time_limit(socket) do
      {:halt, socket} ->
        {:noreply, socket}

      {:ok, socket} ->
        q = socket.assigns.current_question
        answer = Map.get(params, "answer")
        answer_content = normalize_answer(q, answer)

        case Learning.save_question_submission(
               socket.assigns.submission,
               socket.assigns.current_user.id,
               q.id,
               socket.assigns.team_id,
               answer_content
             ) do
          {:ok, child_sub} ->
            new_child_subs = Map.put(socket.assigns.child_submissions, q.id, child_sub)
            {:noreply, assign(socket, :child_submissions, new_child_subs)}

          {:error, :time_limit_exceeded} ->
            {:noreply,
             submit_and_exit(
               socket,
               socket.assigns.submission,
               socket.assigns.course_id,
               :time_limit_exceeded
             )}
        end
    end
  end

  defp normalize_answer(
         %{
           type: :quiz_question,
           content: %{"question_type" => _q_type, "answer_type" => "rich_text"}
         },
         answer
       ) do
    parsed_answer =
      if is_binary(answer) and String.starts_with?(answer, "{") do
        case Jason.decode(answer) do
          {:ok, decoded} -> decoded
          _ -> answer
        end
      else
        answer
      end

    %{"type" => :quiz_question, "rich_answer" => parsed_answer}
  end

  defp normalize_answer(%{type: :quiz_question, content: %{"question_type" => q_type}}, answer) do
    case q_type do
      "single" ->
        %{"type" => :quiz_question, "selected_choices" => if(answer, do: [answer], else: [])}

      "multiple" ->
        %{"type" => :quiz_question, "selected_choices" => List.wrap(answer)}

      "open" ->
        %{"type" => :quiz_question, "text_answer" => answer || ""}

      "exact_match" ->
        %{"type" => :quiz_question, "text_answer" => answer || ""}

      _ ->
        %{"type" => :quiz_question, "text_answer" => answer || ""}
    end
  end

  defp normalize_answer(%{type: :code}, answer) do
    code_str =
      cond do
        is_map(answer) -> Map.get(answer, "code", "")
        is_binary(answer) -> answer
        true -> ""
      end

    %{"type" => :code, "code" => code_str}
  end

  defp normalize_answer(%{type: :file_assignment}, answer) do
    urls = if is_list(answer), do: answer, else: [answer]
    %{"type" => :file_assignment, "file_urls" => Enum.reject(urls, &(&1 == ""))}
  end

  defp normalize_answer(_block, answer) do
    %{"type" => :generic, "text_answer" => answer || ""}
  end

  defp update_question(socket, index) do
    socket
    |> assign(:current_index, index)
    |> assign(:current_question, Enum.at(socket.assigns.questions, index))
  end

  defp submit_and_exit(socket, submission, course_id, reason) do
    initial_status = if reason == :time_limit_exceeded, do: "time_limit_exceeded", else: "pending"

    {:ok, pending_sub} =
      Learning.system_update_submission(submission, %{"status" => initial_status})

    if initial_status == "pending" do
      eval_results = Athena.Learning.Evaluator.evaluate_sync(pending_sub)

      {:ok, _} = Learning.system_update_submission(pending_sub, eval_results)
    end

    broadcast_team_progress(socket.assigns.team_id, course_id)

    msg =
      if reason == :time_limit_exceeded,
        do: gettext("Time is up! Your exam has been automatically submitted."),
        else: gettext("Exam submitted successfully!")

    socket
    |> put_flash(:info, msg)
    |> push_navigate(to: socket.assigns.return_to)
  end

  defp format_time(seconds) when seconds > 0 do
    m = div(seconds, 60)
    s = rem(seconds, 60)

    "#{String.pad_leading(Integer.to_string(m), 2, "0")}:#{String.pad_leading(Integer.to_string(s), 2, "0")}"
  end

  defp format_time(_), do: "00:00"

  defp maybe_start_timer(socket) do
    if connected?(socket) and not is_nil(socket.assigns.time_limit_sec) do
      Process.send_after(self(), :tick, 1000)
    end
  end

  defp broadcast_team_progress(nil, _course_id), do: :ok

  defp broadcast_team_progress(team_id, course_id) do
    Phoenix.PubSub.broadcast(Athena.PubSub, "team_progress:#{team_id}", :team_progress_updated)
    Phoenix.PubSub.broadcast(Athena.PubSub, "leaderboard:#{course_id}", :update_leaderboard)
  end

  defp get_time_limit_sec(block) do
    content = block.content || %{}

    case Map.get(content, "time_limit") do
      nil ->
        3600

      minutes when is_integer(minutes) ->
        minutes * 60

      minutes when is_binary(minutes) ->
        case Integer.parse(minutes) do
          {mins, _} -> mins * 60
          :error -> 3600
        end
    end
  end

  defp hydrate_questions(questions) when is_list(questions) do
    Enum.map(questions, fn q ->
      q_map = if is_struct(q), do: Map.from_struct(q), else: q
      type_raw = Map.get(q_map, "type") || Map.get(q_map, :type)
      type = if is_binary(type_raw), do: String.to_atom(type_raw), else: type_raw
      content = Map.get(q_map, "content") || Map.get(q_map, :content) || %{}
      id = Map.get(q_map, "id") || Map.get(q_map, :id)

      %{id: id, type: type, content: content}
    end)
  end

  defp hydrate_questions(_), do: []

  defp save_exam_file_assignment(socket, block_id, file_urls) do
    answer_content = %{type: :file_assignment, file_urls: file_urls || []}

    case Learning.save_question_submission(
           socket.assigns.submission,
           socket.assigns.current_user.id,
           block_id,
           socket.assigns.team_id,
           answer_content
         ) do
      {:ok, child_sub} ->
        new_child_subs = Map.put(socket.assigns.child_submissions || %{}, block_id, child_sub)
        assign(socket, :child_submissions, new_child_subs)

      {:error, reason} ->
        require Logger
        Logger.error("Failed to save exam file assignment: #{inspect(reason)}")
        socket
    end
  end

  defp all_questions_answered?(questions, child_submissions),
    do:
      questions
      |> Enum.all?(fn q -> Map.has_key?(child_submissions, q.id) end)
end
