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
  def mount(%{"id" => course_id, "block_id" => block_id}, _session, socket) do
    user = socket.assigns.current_user
    cohort = Learning.get_user_cohort_for_course(user.id, course_id)
    team_id = if cohort && cohort.type == :team, do: cohort.id, else: nil

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
        {:ok, socket, layout: false}
      else
        questions = hydrate_questions(submission.content["questions"] || [])
        child_subs = Learning.get_child_submissions(submission.id)

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
          |> assign(:cheat_count, Map.get(submission.content || %{}, "cheat_count", 0))
          |> assign(:max_cheats, Map.get(block.content || %{}, "allowed_blur_attempts", 3))
          |> assign(:pending_file_urls, %{})
          |> assign(:show_media_modal, false)
          |> assign(:active_upload_block_id, nil)
          |> assign(:upload_type, nil)
          |> assign(:max_files_for_upload, 1)
          |> assign(:current_file_count_for_upload, 0)

        maybe_start_timer(socket)
        {:ok, socket, layout: false}
      end
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
      {:noreply, assign(socket, :time_left, time_left)}
    end
  end

  @impl true
  def handle_event("cheat_detected", _params, socket) do
    case check_time_limit(socket) do
      {:halt, socket} ->
        {:noreply, socket}

      {:ok, socket} ->
        new_count = socket.assigns.cheat_count + 1
        max_cheats = socket.assigns.max_cheats

        new_content = Map.put(socket.assigns.submission.content || %{}, "cheat_count", new_count)

        {:ok, updated_sub} =
          Learning.system_update_submission(socket.assigns.submission, %{"content" => new_content})

        socket = assign(socket, submission: updated_sub, cheat_count: new_count)

        if new_count >= max_cheats do
          {:ok, _failed_sub} =
            Learning.system_update_submission(updated_sub, %{"status" => "graded", "score" => 0})

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
  end

  @impl true
  def handle_event("save_answer", params, socket) do
    process_exam_answer(params, socket)
  end

  @impl true
  def handle_event("save_draft", params, socket) do
    process_exam_answer(params, socket)
  end

  def handle_event("save_draft", _params, socket), do: {:noreply, socket}
  def handle_event("save_answer", _params, socket), do: {:noreply, socket}

  @impl true
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
          {:noreply,
           put_flash(socket, :error, gettext("Неверный тип блока для загрузки файлов."))}
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
      {:noreply, put_flash(socket, :error, gettext("Достигнут лимит количества файлов."))}
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
      {:noreply, put_flash(socket, :error, gettext("Пожалуйста, загрузите хотя бы один файл."))}
    else
      child_sub = Map.get(socket.assigns.child_submissions, block_id)

      if child_sub do
        {:ok, updated_sub} =
          Learning.system_update_submission(child_sub, %{"status" => "pending"})

        new_child_subs = Map.put(socket.assigns.child_submissions, block_id, updated_sub)

        {:noreply,
         socket
         |> assign(:child_submissions, new_child_subs)
         |> put_flash(:info, gettext("Файлы успешно отправлены!"))}
      else
        {:noreply, put_flash(socket, :error, gettext("Ошибка отправки задания."))}
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
          gettext("Не удалось сохранить %{count} файл(ов)", count: error_count)
        )
      else
        put_flash(socket, :info, gettext("Файл(ы) готовы к отправке"))
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info({AthenaWeb.StudioLive.MediaUploadComponent, msg}, socket) do
    require Logger
    Logger.warning("⚠️ Получено неизвестное сообщение от MediaUploadComponent: #{inspect(msg)}")
    {:noreply, socket}
  end

  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  @impl true
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

  @impl true
  def handle_event("prev_question", _, socket) do
    case check_time_limit(socket) do
      {:halt, socket} ->
        {:noreply, socket}

      {:ok, socket} ->
        prev_idx = max(socket.assigns.current_index - 1, 0)
        {:noreply, update_question(socket, prev_idx)}
    end
  end

  @impl true
  def handle_event("jump_to", %{"index" => idx_str}, socket) do
    case check_time_limit(socket) do
      {:halt, socket} ->
        {:noreply, socket}

      {:ok, socket} ->
        idx = String.to_integer(idx_str)
        {:noreply, update_question(socket, idx)}
    end
  end

  @impl true
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
  def render(assigns) do
    ~H"""
    <div id="exam-container" phx-hook="AntiCheat" class="min-h-screen bg-base-200 flex flex-col">
      <header class="bg-base-100 border-b border-base-300 p-4 sticky top-0 z-50 flex items-center justify-between">
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
        <aside class="w-full md:w-64 shrink-0 bg-base-100 p-4 rounded-2xl border border-base-300 sticky top-24">
          <div class="text-xs font-bold uppercase tracking-widest text-base-content/50 mb-4 text-center">
            {gettext("Questions Navigation")}
          </div>
          <div class="flex flex-wrap gap-2 justify-center">
            <%= for {q, index} <- Enum.with_index(@questions) do %>
              <button
                phx-click="jump_to"
                phx-value-index={index}
                class={[
                  "size-10 rounded-lg font-bold flex items-center justify-center transition-all",
                  @current_index == index && "ring-2 ring-primary ring-offset-2 ring-offset-base-100",
                  @current_index != index && "hover:bg-base-200",
                  Map.has_key?(@child_submissions, q.id) &&
                    "bg-primary/10 text-primary border border-primary/30",
                  not Map.has_key?(@child_submissions, q.id) && "bg-base-200 text-base-content/60"
                ]}
              >
                {index + 1}
              </button>
            <% end %>
          </div>
        </aside>

        <main class="flex-1 bg-base-100 p-6 md:p-10 rounded-2xl border border-base-300 w-full">
          <%= if @current_question do %>
            <div class="flex items-center gap-3 mb-6 pb-6 border-b border-base-200">
              <div class="size-10 bg-primary text-primary-content font-black rounded-xl flex items-center justify-center text-xl">
                {@current_index + 1}
              </div>
              <h2 class="text-xl font-bold text-base-content/50 uppercase tracking-widest">
                {gettext("Question")}
              </h2>
            </div>

            <form phx-change="save_answer" phx-submit="next_question">
              <.content_block
                block={@current_question}
                mode={:play}
                submission={Map.get(@child_submissions, @current_question.id)}
                pending_file_urls={@pending_file_urls}
              />

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
           content: %{"question_type" => q_type, "answer_type" => "rich_text"}
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
    status = if reason == :time_limit_exceeded, do: "time_limit_exceeded", else: "needs_review"

    {:ok, _} = Learning.system_update_submission(submission, %{"status" => status})
    broadcast_team_progress(socket.assigns.team_id, course_id)

    msg =
      if reason == :time_limit_exceeded,
        do: gettext("Time is up! Your exam has been automatically submitted."),
        else: gettext("Exam submitted successfully!")

    socket
    |> put_flash(:info, msg)
    |> push_navigate(to: ~p"/learn/courses/#{course_id}")
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
        Logger.error("❌ Ошибка сохранения файлов в экзамене: #{inspect(reason)}")
        socket
    end
  end
end
