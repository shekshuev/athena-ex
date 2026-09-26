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

  alias Athena.{Content, Engagement, Learning}
  alias AthenaWeb.LearnLive.EngagementSignals
  import AthenaWeb.BlockComponents

  @impl true
  def mount(%{"id" => course_id, "block_id" => block_id} = params, _session, socket) do
    user = socket.assigns.current_user
    cohort = Learning.get_user_cohort_for_course(user.id, course_id)
    team_id = if cohort && cohort.type == :team, do: cohort.id, else: nil
    cohort_id = cohort && cohort.id

    return_to = Map.get(params, "return_to", ~p"/learn/courses/#{course_id}/play")

    with {:ok, block} <- Content.get_block(block_id),
         time_limit_sec <- get_time_limit_sec(block) do
      case Learning.get_or_create_exam_attempt(
             course_id,
             user.id,
             block_id,
             block.type,
             team_id,
             time_limit_sec,
             block.content
           ) do
        {:ok, submission} ->
          handle_exam_mount(
            socket,
            block,
            submission,
            course_id,
            team_id,
            cohort_id,
            time_limit_sec,
            return_to
          )

        # Already graded/rejected/needs review/timed out - most commonly hit
        # by pressing "back" in the browser right after finishing, which
        # would otherwise silently start a brand new attempt (see
        # `Submissions.get_or_create_exam_attempt/7`). A real retake goes
        # through an instructor deleting the old submission instead.
        {:already_completed, _submission} ->
          {:ok,
           socket
           |> put_flash(:info, gettext("You've already completed this assessment session."))
           |> push_navigate(to: return_to)}

        _ ->
          {:ok,
           socket
           |> put_flash(
             :error,
             gettext("Assessment session is not active or already finished.")
           )
           |> push_navigate(to: ~p"/learn/courses/#{course_id}")}
      end
    else
      _ ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Assessment session is not active or already finished."))
         |> push_navigate(to: ~p"/learn/courses/#{course_id}")}
    end
  end

  defp handle_exam_mount(
         socket,
         block,
         submission,
         course_id,
         team_id,
         cohort_id,
         time_limit_sec,
         return_to
       ) do
    if DateTime.compare(DateTime.utc_now(), submission.expires_at) == :gt do
      # `submit_and_exit` reads `socket.assigns.team_id`/`:return_to` (for
      # `broadcast_team_progress/2` and the post-submit redirect) and
      # `:cohort_id`/`:block` (for `Engagement.finalize_proctoring/4`);
      # normally set by `setup_exam_state`, but this bail-out path skips
      # straight past it, so assign them here too.
      socket =
        assign(socket, team_id: team_id, cohort_id: cohort_id, block: block, return_to: return_to)

      {:ok, submit_and_exit(socket, submission, course_id, :time_limit_exceeded)}
    else
      setup_exam_state(
        socket,
        block,
        submission,
        course_id,
        team_id,
        cohort_id,
        time_limit_sec,
        return_to
      )
    end
  end

  defp setup_exam_state(
         socket,
         block,
         submission,
         course_id,
         team_id,
         cohort_id,
         time_limit_sec,
         return_to
       ) do
    questions = hydrate_questions(submission.content["questions"] || [])
    child_subs = Learning.get_child_submissions(submission.id)
    pending_urls = build_pending_urls(child_subs)

    if connected?(socket) do
      # The exam's own submission - an instructor rejecting a cheater from
      # the grading screen, or another tab finalizing it, must end this
      # session immediately (see `handle_info({:submission_updated, ...})`
      # below), not only once the student submits or times out.
      Phoenix.PubSub.subscribe(
        Athena.PubSub,
        "submission:#{socket.assigns.current_user.id}:#{block.id}"
      )

      Enum.each(questions, fn q ->
        Phoenix.PubSub.subscribe(
          Athena.PubSub,
          "submission:#{socket.assigns.current_user.id}:#{q.id}"
        )
      end)
    end

    socket =
      socket
      |> assign(
        course_id: course_id,
        team_id: team_id,
        cohort_id: cohort_id,
        engagement_session_id: Ecto.UUID.generate(),
        engagement_answered_blocks: MapSet.new(),
        block: block,
        submission: submission,
        questions: questions,
        current_index: 0,
        current_question: Enum.at(questions, 0),
        child_submissions: child_subs,
        time_limit_sec: time_limit_sec,
        time_left: DateTime.diff(submission.expires_at, DateTime.utc_now()),
        pending_file_urls: pending_urls,
        show_media_modal: false,
        show_finish_modal: false,
        return_to: return_to,
        active_upload_block_id: nil,
        upload_type: nil,
        max_files_for_upload: 1,
        current_file_count_for_upload: 0
      )

    maybe_start_timer(socket)
    {:ok, socket}
  end

  defp build_pending_urls(child_subs) do
    Enum.reduce(child_subs, %{}, fn {q_id, sub}, acc ->
      content = sub.content || %{}

      if content["type"] in ["file_assignment", :file_assignment] do
        Map.put(acc, q_id, content["file_urls"] || [])
      else
        acc
      end
    end)
  end

  @impl true
  def handle_event("save_answer", params, socket) do
    process_exam_answer(params, socket)
  end

  def handle_event("save_draft", params, socket) do
    process_exam_answer(params, socket)
  end

  def handle_event("update_content", %{"id" => block_id, "content" => content}, socket) do
    params = %{"block_id" => block_id, "answer" => content}
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
        "reorder_matching_answer",
        %{"old_index" => old_index, "new_index" => new_index},
        socket
      ) do
    q = socket.assigns.current_question
    current_order = current_exam_matching_order(socket, q)
    new_order = move_item(current_order, old_index, new_index)
    process_exam_answer(%{"answer" => new_order}, socket)
  end

  def handle_event("move_matching_answer_up", %{"id" => pair_id}, socket) do
    shift_exam_matching_answer(socket, pair_id, -1)
  end

  def handle_event("move_matching_answer_down", %{"id" => pair_id}, socket) do
    shift_exam_matching_answer(socket, pair_id, 1)
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

  def handle_event(
        "request_media_upload",
        %{"block_id" => block_id, "media_type" => type},
        socket
      ) do
    case check_time_limit(socket) do
      {:halt, socket} ->
        {:noreply, socket}

      {:ok, socket} ->
        {:noreply,
         socket
         |> assign(:show_media_modal, true)
         |> assign(:active_upload_block_id, block_id)
         |> assign(:upload_type, type)
         |> assign(:max_files_for_upload, 1)
         |> assign(:current_file_count_for_upload, 0)}
    end
  end

  def handle_event("media_upload_clipboard_request", params, socket) do
    %{"file_name" => file_name, "temp_id" => temp_id} = params

    bucket = Application.get_env(:athena, Athena.Media)[:bucket] || "athena"
    course_id = socket.assigns.course_id
    unique_id = Ecto.UUID.generate()
    clean_name = file_name |> String.replace(~r/[^a-zA-Z0-9_\-\.]/, "_")
    key = "courses/#{course_id}/#{unique_id}-#{clean_name}"

    case Athena.Media.generate_upload_url(bucket, key) do
      {:ok, upload_url} ->
        path_segments = String.split(key, "/")
        final_url = ~p"/media/#{path_segments}"

        {:noreply,
         push_event(socket, "media_upload_presigned", %{
           temp_id: temp_id,
           upload_url: upload_url,
           final_url: final_url
         })}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not generate upload URL"))}
    end
  end

  def handle_event(
        "media_upload_clipboard_success",
        %{"block_id" => block_id, "final_url" => url},
        socket
      ) do
    block = Enum.find(socket.assigns.questions, &(&1.id == block_id))

    if block && to_string(block.type) == "file_assignment" do
      pending = socket.assigns.pending_file_urls || %{}
      current_urls = Map.get(pending, block_id, [])
      max_files = block.content["max_files"] || 1

      if length(current_urls) < max_files do
        updated_urls = current_urls ++ [url]
        updated_pending = Map.put(pending, block_id, updated_urls)

        socket = save_exam_file_assignment(socket, block_id, updated_urls)

        {:noreply, assign(socket, :pending_file_urls, updated_pending)}
      else
        {:noreply, put_flash(socket, :error, gettext("Maximum number of files reached."))}
      end
    else
      {:noreply,
       push_event(socket, "insert_media", %{
         block_id: block_id,
         url: url,
         type: "tiptap_image"
       })}
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
      {:halt, socket} -> {:noreply, socket}
      {:ok, socket} -> execute_run_code(socket, block_id)
    end
  end

  def handle_event("engagement_batch", %{"events" => events}, socket) do
    section_id = socket.assigns.block.section_id

    normalized =
      events
      |> Enum.map(&Engagement.normalize_event(&1, section_id))
      |> Enum.reject(&is_nil/1)

    Engagement.record_events(
      socket.assigns.current_user.id,
      socket.assigns.cohort_id,
      socket.assigns.engagement_session_id,
      normalized
    )

    Engagement.report_proctoring_events(
      socket.assigns.submission.id,
      socket.assigns.cohort_id,
      socket.assigns.block.id,
      normalized
    )

    {:noreply, socket}
  end

  defp execute_run_code(socket, block_id) do
    socket = EngagementSignals.emit_code_run_attempt(socket, block_id)
    submission_to_run = resolve_submission_for_run(socket, block_id)

    if submission_to_run do
      case Learning.enqueue_code_execution(submission_to_run) do
        {:ok, processing_sub} ->
          new_child_subs = Map.put(socket.assigns.child_submissions, block_id, processing_sub)
          {:noreply, assign(socket, :child_submissions, new_child_subs)}

        {:error, _err} ->
          {:noreply, put_flash(socket, :error, gettext("Failed to start code execution."))}
      end
    else
      {:noreply, socket}
    end
  end

  defp resolve_submission_for_run(socket, block_id) do
    child_sub = Map.get(socket.assigns.child_submissions, block_id)

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

  def handle_info(
        {AthenaWeb.StudioLive.MediaUploadComponent, {:saved, block_id, "tiptap_image", results}},
        socket
      ) do
    {successes, _errors} = Enum.split_with(results, &match?({:ok, _}, &1))
    file_urls = Enum.map(successes, fn {:ok, map} -> map["url"] end) |> Enum.reject(&is_nil/1)

    socket =
      socket
      |> assign(:show_media_modal, false)
      |> assign(:active_upload_block_id, nil)
      |> assign(:upload_type, nil)

    case List.first(file_urls) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Failed to upload image"))}

      url ->
        {:noreply,
         push_event(socket, "insert_media", %{
           block_id: block_id,
           url: url,
           type: "tiptap_image"
         })}
    end
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

  # The exam's own submission was ended by someone else - an instructor
  # rejecting a cheater from the grading screen (or another tab/device
  # finalizing it) - while the student still has this page open. It's
  # already graded/rejected in the DB; just get them off the exam now
  # instead of letting them keep answering an attempt that's already over.
  @impl true
  def handle_info(
        {:submission_updated, %{id: id, status: status}},
        %{assigns: %{submission: %{id: id}}} = socket
      )
      when status != :pending do
    msg =
      if status == :rejected,
        do: gettext("Your instructor ended this assessment session."),
        else: gettext("This assessment session has already been finished.")

    {:noreply,
     socket
     |> put_flash(:warning, msg)
     |> push_navigate(to: socket.assigns.return_to)}
  end

  @impl true
  def handle_info({:submission_updated, updated_sub}, socket) do
    new_child_subs = Map.put(socket.assigns.child_submissions, updated_sub.block_id, updated_sub)

    socket =
      if updated_sub.status in [:pending, :processing, :draft] do
        socket
      else
        EngagementSignals.emit_code_run_result(socket, updated_sub.block_id, updated_sub.status)
      end

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
    <div
      id="engagement-tracker"
      phx-hook="EngagementTracker"
      data-session-id={@engagement_session_id}
      class="flex flex-col min-h-screen"
    >
      <div
        id={"multi-tab-guard-#{@submission.id}"}
        phx-hook="MultiTabGuard"
        phx-update="ignore"
        data-submission-id={@submission.id}
        data-block-id={@block.id}
        class="hidden"
      >
      </div>
      <header class="bg-base-100 border-b border-base-300">
        <.page_container size="wide" class="px-4 sm:px-6 lg:px-8">
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
                    else: "bg-base-100 border-base-300 text-base-content"
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
        </.page_container>

        <div class="border-t border-base-300 bg-base-100">
          <.page_container size="wide" class="px-4 sm:px-6 lg:px-8 py-3">
            <div class="flex items-center gap-2 overflow-x-auto scrollbar-thin scrollbar-thumb-base-300 scrollbar-track-transparent pb-1">
              <%= for {q, index} <- Enum.with_index(@questions) do %>
                <button
                  phx-click="jump_to"
                  phx-value-index={index}
                  class={[
                    "size-9 rounded-sm font-bold text-sm flex items-center justify-center transition-all shrink-0 border",
                    @current_index == index && "bg-primary text-primary-content border-primary",
                    @current_index != index && Map.has_key?(@child_submissions, q.id) &&
                      "bg-success/10 text-success border-success hover:bg-success/20",
                    @current_index != index && not Map.has_key?(@child_submissions, q.id) &&
                      "bg-base-100 text-base-content/60 border-base-300 hover:border-primary hover:text-primary"
                  ]}
                  title={gettext("Question %{num}", num: index + 1)}
                >
                  {index + 1}
                </button>
              <% end %>
            </div>
          </.page_container>
        </div>
      </header>

      <main class="flex-1 bg-base-100 py-8 px-4 sm:px-6 lg:px-8">
        <div class="max-w-4xl mx-auto">
          <%= if @current_question do %>
            <div
              id={"exam-question-wrapper-#{@current_question.id}"}
              data-block-id={@current_question.id}
              data-block-type={@current_question.type}
              class="bg-base-100 border border-base-300 rounded-sm"
            >
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
                        user_id={@current_user.id}
                        proctoring={true}
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

              <div class="flex items-center justify-between p-6 border-t border-base-300">
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
        title={gettext("Submit Assessment Session?")}
        description={
          gettext(
            "Are you sure you want to finish? You won't be able to change your answers after submission."
          )
        }
        confirm_label={gettext("Yes, Submit")}
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
        answer = resolve_exam_answer(socket, q, Map.get(params, "answer"))
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

            socket =
              socket
              |> assign(:child_submissions, new_child_subs)
              |> EngagementSignals.record_quiz_interaction(q)

            {:noreply, socket}

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

  defp normalize_answer(%{type: :quiz_question, content: %{"question_type" => "single"}}, answer) do
    %{"type" => :quiz_question, "selected_choices" => if(answer, do: [answer], else: [])}
  end

  defp normalize_answer(
         %{type: :quiz_question, content: %{"question_type" => "multiple"}},
         answer
       ) do
    %{"type" => :quiz_question, "selected_choices" => List.wrap(answer)}
  end

  defp normalize_answer(
         %{type: :quiz_question, content: %{"question_type" => "matching"}},
         answer
       ) do
    %{"type" => :quiz_question, "matches" => answer || []}
  end

  defp normalize_answer(%{type: :quiz_question, content: %{"question_type" => _other}}, answer) do
    %{"type" => :quiz_question, "text_answer" => answer || ""}
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

  @doc false
  defp resolve_exam_answer(socket, %{content: %{"question_type" => "matching"}} = q, nil) do
    current_exam_matching_order(socket, q)
  end

  defp resolve_exam_answer(_socket, _q, answer), do: answer

  @doc false
  defp current_exam_matching_order(socket, q) do
    pairs = q.content["pairs"] || []
    existing_sub = Map.get(socket.assigns.child_submissions, q.id)
    existing_matches = existing_sub && existing_sub.content["matches"]

    case existing_matches do
      list when is_list(list) and list != [] ->
        list

      _ ->
        initial_matching_order(pairs, q.id, socket.assigns.current_user.id)
    end
  end

  @doc false
  defp move_item(list, old_index, new_index) do
    {item, rest} = List.pop_at(list, old_index)
    List.insert_at(rest, new_index, item)
  end

  @doc false
  defp shift_exam_matching_answer(socket, pair_id, delta) do
    q = socket.assigns.current_question
    current_order = current_exam_matching_order(socket, q)

    case Enum.find_index(current_order, &(&1 == pair_id)) do
      nil ->
        {:noreply, socket}

      old_index ->
        new_index = (old_index + delta) |> max(0) |> min(length(current_order) - 1)

        if new_index == old_index do
          {:noreply, socket}
        else
          new_order = move_item(current_order, old_index, new_index)
          process_exam_answer(%{"answer" => new_order}, socket)
        end
    end
  end

  defp update_question(socket, index) do
    socket
    |> assign(:current_index, index)
    |> assign(:current_question, Enum.at(socket.assigns.questions, index))
  end

  defp submit_and_exit(socket, submission, course_id, reason) do
    block = Map.get(socket.assigns, :block)
    allowed_blur_attempts = (block && block.content["allowed_blur_attempts"]) || 3

    proctoring_fields =
      Engagement.finalize_proctoring(
        submission.id,
        Map.get(socket.assigns, :cohort_id),
        block && block.id,
        allowed_blur_attempts
      )

    updated_content = Map.merge(submission.content || %{}, proctoring_fields)

    {:ok, submission} =
      Learning.system_update_submission(submission, %{"content" => updated_content})

    final_sub =
      case reason do
        :time_limit_exceeded ->
          # Scores it (open/code/file answers still land in :needs_review for
          # manual grading) and stamps :time_limit_exceeded instead of
          # :graded, so the student sees both why it ended and their score.
          # Idempotent - already a no-op if `get_or_create_exam_attempt`
          # finalized this attempt on a prior mount.
          {:ok, sub} = Learning.finalize_expired_exam(submission)
          sub

        _ ->
          {:ok, pending_sub} =
            Learning.system_update_submission(submission, %{"status" => "pending"})

          eval_results = Learning.evaluate_sync(pending_sub)

          {:ok, graded_sub} = Learning.system_update_submission(pending_sub, eval_results)
          graded_sub
      end

    Learning.maybe_complete_from_submission(final_sub)

    broadcast_team_progress(socket.assigns.team_id, course_id)

    msg =
      if reason == :time_limit_exceeded,
        do: gettext("Time is up! Your assessment session has been automatically submitted."),
        else: gettext("Assessment session submitted successfully!")

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
    answer_content = %{"type" => "file_assignment", "file_urls" => file_urls || []}

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
