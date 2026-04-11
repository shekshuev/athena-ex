defmodule AthenaWeb.LearnLive.Player do
  @moduledoc """
  The core learning interface: Progressive Disclosure Player.

  Enforces strict Waterfall progression through course content. Handles
  the rendering of various block types (text, media, code) and manages
  interactive progression gates (e.g., "Require Button Click", "Pass Auto-Grade").

  Features real-time synchronization via PubSub to immediately react to
  instructor changes (like hiding a section or locking it with a timer)
  and safely boot the student back to the syllabus if access is revoked.
  """
  use AthenaWeb, :live_view

  alias Athena.Content
  alias Athena.Learning
  import AthenaWeb.BlockComponents

  @doc """
  Initializes the player, checks course access, and validates that the student
  has reached the requested section. Redirects to a safe zone if access is blocked.
  """
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  @impl true
  def mount(%{"id" => course_id} = params, _session, socket) do
    user = socket.assigns.current_user

    with true <- Learning.has_access?(user.id, course_id),
         {:ok, course} <- Content.get_course(course_id) do
      if connected?(socket) do
        Phoenix.PubSub.subscribe(Athena.PubSub, "course_content:#{course_id}")
      end

      linear_lessons = Content.list_linear_lessons(course_id, user)
      accessible_ids = Learning.accessible_section_ids(user.id, course_id, linear_lessons)

      first_lesson_id = linear_lessons |> List.first() |> Map.get(:id)
      section_id = params["section_id"] || first_lesson_id

      if section_id in accessible_ids do
        setup_player_state(socket, course, section_id, linear_lessons, accessible_ids, user)
      else
        {:ok,
         socket
         |> put_flash(:error, gettext("You must complete previous lessons first."))
         |> push_navigate(to: ~p"/learn/courses/#{course_id}")}
      end
    else
      _ ->
        {:ok,
         push_navigate(socket |> put_flash(:error, gettext("Access denied.")), to: ~p"/learn")}
    end
  end

  @doc false
  defp setup_player_state(socket, course, section_id, linear_lessons, accessible_ids, user) do
    section = Content.get_section(section_id) |> elem(1)

    blocks = Content.list_blocks_by_section(section_id, user) |> Enum.sort_by(& &1.order)
    completed_ids = Learning.completed_block_ids(user.id, section_id)
    tree = Content.get_course_tree(course.id, user)

    current_index = Enum.find_index(linear_lessons, fn s -> s.id == section_id end)

    prev_section = if current_index > 0, do: Enum.at(linear_lessons, current_index - 1), else: nil
    next_section = Enum.at(linear_lessons, current_index + 1)
    next_accessible? = next_section != nil and next_section.id in accessible_ids

    submissions = Learning.get_latest_submissions(user.id, Enum.map(blocks, & &1.id))

    socket =
      socket
      |> assign(:page_title, section.title)
      |> assign(:course, course)
      |> assign(:tree, tree)
      |> assign(:linear_lessons, linear_lessons)
      |> assign(:section, section)
      |> assign(:blocks, blocks)
      |> assign(:completed_ids, completed_ids)
      |> assign(:prev_section_id, if(prev_section, do: prev_section.id, else: nil))
      |> assign(:next_section_id, if(next_accessible?, do: next_section.id, else: nil))
      |> assign(:course_map_open, false)
      |> assign(:visible_blocks, calc_visible_blocks(blocks, completed_ids))
      |> assign(:submissions, submissions)

    {:ok, schedule_next_unlock(socket, course.id)}
  end

  @doc """
  Handles progression gates. When a student completes a mandatory block,
  this records the progress and dynamically unlocks the rest of the content.
  """
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  @impl true
  def handle_event("complete_gate", %{"block-id" => block_id}, socket) do
    user = socket.assigns.current_user
    {:ok, _} = Learning.mark_completed(user.id, block_id)
    new_completed_ids = [block_id | socket.assigns.completed_ids]

    linear_lessons = socket.assigns.linear_lessons

    accessible_ids =
      Learning.accessible_section_ids(user.id, socket.assigns.course.id, linear_lessons)

    current_index = Enum.find_index(linear_lessons, fn s -> s.id == socket.assigns.section.id end)
    next_section = Enum.at(linear_lessons, current_index + 1)
    next_accessible? = next_section != nil and next_section.id in accessible_ids

    {:noreply,
     socket
     |> assign(:completed_ids, new_completed_ids)
     |> assign(:next_section_id, if(next_accessible?, do: next_section.id, else: nil))
     |> assign(:visible_blocks, calc_visible_blocks(socket.assigns.blocks, new_completed_ids))}
  end

  def handle_event("open_course_map", _, socket),
    do: {:noreply, assign(socket, course_map_open: true)}

  def handle_event("close_course_map", _, socket),
    do: {:noreply, assign(socket, course_map_open: false)}

  @impl true
  def handle_event("start_exam", %{"block_id" => block_id}, socket) do
    user = socket.assigns.current_user
    block = Enum.find(socket.assigns.blocks, &(&1.id == block_id))

    if block && block.type == :quiz_exam do
      questions = Content.generate_exam_questions(block.content)

      sub_attrs = %{
        account_id: user.id,
        block_id: block.id,
        status: :pending,
        content: %{
          type: :quiz_exam,
          started_at: DateTime.utc_now(),
          questions: questions,
          answers: %{},
          cheat_count: 0
        }
      }

      case Learning.create_submission(sub_attrs) do
        {:ok, _submission} ->
          {:noreply,
           push_navigate(socket,
             to: ~p"/learn/courses/#{socket.assigns.course.id}/exam/#{block.id}"
           )}

        {:error, _} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             gettext("Failed to start the exam. Not enough questions in library.")
           )}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("continue_exam", %{"block_id" => block_id}, socket) do
    {:noreply,
     push_navigate(socket, to: ~p"/learn/courses/#{socket.assigns.course.id}/exam/#{block_id}")}
  end

  @impl true
  def handle_event("submit_quiz", %{"block_id" => block_id} = params, socket) do
    case Enum.find(socket.assigns.blocks, &(&1.id == block_id)) do
      nil ->
        {:noreply, socket}

      block ->
        handle_quiz_submission(socket, block, params["answer"])
    end
  end

  @doc false
  defp handle_quiz_submission(socket, block, answer) do
    sub_attrs = %{
      account_id: socket.assigns.current_user.id,
      block_id: block.id,
      status: :pending,
      content: build_submission_content(block, answer)
    }

    case Learning.create_submission(sub_attrs) do
      {:ok, submission} ->
        eval_result = Learning.evaluate_sync(submission)
        {:ok, final_sub} = Learning.update_submission(submission, eval_result)

        submissions = Map.put(socket.assigns.submissions || %{}, block.id, final_sub)
        socket = assign(socket, submissions: submissions)

        {:noreply, process_gate_after_submission(socket, block, final_sub)}

      {:error, changeset} ->
        error_msg =
          changeset.errors
          |> Keyword.values()
          |> Enum.map_join(", ", fn {msg, _} -> msg end)

        {:noreply, put_flash(socket, :error, error_msg)}
    end
  end

  @doc false
  defp calc_visible_blocks(blocks, completed_ids) do
    Enum.reduce_while(blocks, [], fn block, acc ->
      is_completed = block.id in completed_ids

      if gate?(block) and not is_completed do
        {:halt, acc ++ [block]}
      else
        {:cont, acc ++ [block]}
      end
    end)
  end

  @doc false
  defp build_submission_content(block, answer) do
    case block.content["question_type"] do
      "exact_match" -> %{type: :quiz_question, text_answer: answer || ""}
      "open" -> %{type: :quiz_question, text_answer: answer || ""}
      "single" -> %{type: :quiz_question, selected_choices: if(answer, do: [answer], else: [])}
      "multiple" -> %{type: :quiz_question, selected_choices: List.wrap(answer)}
      _ -> %{type: :quiz_question}
    end
  end

  @doc false
  defp process_gate_after_submission(socket, block, submission) do
    cond do
      block.id in socket.assigns.completed_ids ->
        socket

      gate_passed?(block.completion_rule, submission) ->
        unlock_next_content(socket, block.id)

      true ->
        socket
    end
  end

  @doc false
  defp gate_passed?(%{type: :submit}, _submission), do: true

  defp gate_passed?(%{type: :pass_auto_grade, min_score: min_score}, submission) do
    submission.score >= (min_score || 0)
  end

  defp gate_passed?(_rule, _submission), do: false

  @doc false
  defp unlock_next_content(socket, block_id) do
    user = socket.assigns.current_user
    {:ok, _} = Learning.mark_completed(user.id, block_id)

    new_completed_ids = [block_id | socket.assigns.completed_ids]
    linear_lessons = socket.assigns.linear_lessons

    accessible_ids =
      Learning.accessible_section_ids(user.id, socket.assigns.course.id, linear_lessons)

    current_index =
      Enum.find_index(linear_lessons, fn s -> s.id == socket.assigns.section.id end)

    next_section = Enum.at(linear_lessons, current_index + 1)
    next_accessible? = next_section != nil and next_section.id in accessible_ids

    socket
    |> assign(:completed_ids, new_completed_ids)
    |> assign(:next_section_id, if(next_accessible?, do: next_section.id, else: nil))
    |> assign(:visible_blocks, calc_visible_blocks(socket.assigns.blocks, new_completed_ids))
  end

  @doc """
  Real-time event handler for content updates.
  Re-evaluates access; if the current section was hidden/locked by the instructor,
  it boots the student back to the safe zone (syllabus).
  """
  @spec handle_info(atom() | tuple(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  @impl true
  def handle_info(:refresh_content, socket) do
    user = socket.assigns.current_user
    course_id = socket.assigns.course.id
    current_section_id = socket.assigns.section.id

    linear_lessons = Content.list_linear_lessons(course_id, user)
    accessible_ids = Learning.accessible_section_ids(user.id, course_id, linear_lessons)

    if current_section_id in accessible_ids do
      blocks =
        Content.list_blocks_by_section(current_section_id, user) |> Enum.sort_by(& &1.order)

      completed_ids = Learning.completed_block_ids(user.id, current_section_id)
      tree = Content.get_course_tree(course_id, user)

      current_index = Enum.find_index(linear_lessons, fn s -> s.id == current_section_id end)
      next_section = Enum.at(linear_lessons, current_index + 1)
      next_accessible? = next_section != nil and next_section.id in accessible_ids

      {:noreply,
       socket
       |> assign(:tree, tree)
       |> assign(:linear_lessons, linear_lessons)
       |> assign(:blocks, blocks)
       |> assign(:completed_ids, completed_ids)
       |> assign(:next_section_id, if(next_accessible?, do: next_section.id, else: nil))
       |> assign(:visible_blocks, calc_visible_blocks(blocks, completed_ids))
       |> schedule_next_unlock(course_id)}
    else
      {:noreply,
       socket
       |> put_flash(
         :warning,
         gettext("The instructor modified this content. Returning to safe zone.")
       )
       |> push_navigate(to: ~p"/learn/courses/#{course_id}")}
    end
  end

  defp gate?(block), do: block.completion_rule && block.completion_rule.type != :none

  defp all_blocks_completed?(visible_blocks, completed_ids) do
    last_block = List.last(visible_blocks)
    last_block == nil or (!gate?(last_block) or last_block.id in completed_ids)
  end

  @doc "Renders the interactive course player UI."
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-3xl mx-auto py-10 pb-32">
      <div class="flex items-center justify-between mb-12 border-b border-base-200 pb-6">
        <a
          href={"/learn/courses/#{@course.id}"}
          class="inline-flex items-center gap-2 text-sm font-medium text-base-content/50 hover:text-base-content transition-colors"
        >
          <.icon name="hero-arrow-left" class="size-4" />
          <span class="hidden sm:inline">{gettext("Back to Syllabus")}</span>
        </a>

        <div class="flex items-center gap-2">
          <%= if @prev_section_id do %>
            <.link
              navigate={~p"/learn/courses/#{@course.id}/play/#{@prev_section_id}"}
              class="btn btn-ghost btn-sm btn-square text-base-content/70 hover:text-primary"
            >
              <.icon name="hero-chevron-left" class="size-5" />
            </.link>
          <% end %>

          <button
            phx-click="open_course_map"
            class="btn btn-ghost btn-sm text-base-content/70 hover:text-primary"
          >
            <.icon name="hero-map" class="size-4" />
            <span class="hidden sm:inline">{gettext("Course Map")}</span>
          </button>

          <%= if @next_section_id && all_blocks_completed?(@visible_blocks, @completed_ids) do %>
            <.link
              navigate={~p"/learn/courses/#{@course.id}/play/#{@next_section_id}"}
              class="btn btn-ghost btn-sm btn-square text-base-content/70 hover:text-primary"
            >
              <.icon name="hero-chevron-right" class="size-5" />
            </.link>
          <% end %>
        </div>
      </div>

      <h1 class="text-3xl md:text-4xl font-display font-black text-base-content mb-12">
        {@section.title}
      </h1>

      <div class="space-y-10">
        <%= for block <- @visible_blocks do %>
          <% submission = Map.get(@submissions || %{}, block.id) %>
          <% is_submitted = submission && submission.status in [:graded, :needs_review] %>
          <% mode = if is_submitted, do: :review, else: :play %>

          <div
            id={"block-wrapper-#{block.id}"}
            class="animate-in slide-in-from-bottom-4 fade-in duration-500 fill-mode-both"
          >
            <%= case block.type do %>
              <% :quiz_question -> %>
                <form phx-submit="submit_quiz" id={"quiz-form-#{block.id}"}>
                  <input type="hidden" name="block_id" value={block.id} />

                  <.content_block block={block} mode={mode} submission={submission} />

                  <div
                    :if={submission && block.content["general_explanation"] not in [nil, ""]}
                    class="mt-4 mb-4 p-4 bg-info/10 text-info-content rounded-xl text-sm border border-info/20"
                  >
                    <strong>{gettext("Explanation:")}</strong> {block.content["general_explanation"]}
                  </div>

                  <div class="mt-6 flex items-center justify-between">
                    <button
                      type="submit"
                      class="btn btn-primary shadow-lg shadow-primary/20"
                      disabled={is_submitted}
                    >
                      {if submission, do: gettext("Submitted"), else: gettext("Submit Answer")}
                    </button>

                    <%= if submission do %>
                      <div
                        :if={submission.status == :graded}
                        class={[
                          "font-bold flex items-center gap-1 text-lg",
                          if(submission.score == 100, do: "text-success", else: "text-error")
                        ]}
                      >
                        <%= if submission.score == 100 do %>
                          <.icon name="hero-check-circle-solid" class="size-6" /> {gettext("Correct!")}
                        <% else %>
                          <.icon name="hero-x-circle-solid" class="size-6" /> {gettext("Incorrect.")}
                        <% end %>
                      </div>

                      <div
                        :if={submission.status == :needs_review}
                        class="font-bold flex items-center gap-1 text-info text-lg"
                      >
                        <.icon name="hero-clock" class="size-6" /> {gettext("Pending Review")}
                      </div>
                    <% end %>
                  </div>
                </form>
              <% :quiz_exam -> %>
                <% exam_mode = if submission, do: :review, else: :play %>
                <div class="relative">
                  <.content_block block={block} mode={exam_mode} submission={submission} />

                  <%= if submission do %>
                    <div class="mt-6 flex justify-center">
                      <%= cond do %>
                        <% submission.status == :graded && (submission.content["cheat_count"] || 0) >= (block.content["allowed_blur_attempts"] || 3) -> %>
                          <div class="inline-flex items-center gap-2 text-xl font-black text-error bg-error/10 px-6 py-3 rounded-2xl">
                            <.icon name="hero-x-circle-solid" class="size-6" />
                            {gettext("Exam Failed (Violations)")}
                          </div>
                        <% submission.status in [:graded, :needs_review] -> %>
                          <div class="inline-flex items-center gap-2 text-xl font-black text-success bg-success/10 px-6 py-3 rounded-2xl">
                            <.icon name="hero-check-circle-solid" class="size-6" />
                            {gettext("Exam Completed")}
                            <span class="ml-2 text-success/50">|</span>
                            <span class="ml-2">{submission.score} / 100</span>
                          </div>
                        <% submission.status == :pending -> %>
                          <button
                            phx-click="continue_exam"
                            phx-value-block_id={block.id}
                            class="btn btn-primary btn-lg px-12 shadow-lg shadow-primary/20"
                          >
                            {gettext("Continue Exam")}
                            <.icon name="hero-arrow-right" class="size-5 ml-2" />
                          </button>
                        <% true -> %>
                      <% end %>
                    </div>
                  <% end %>
                </div>
              <% _ -> %>
                <.content_block block={block} mode={:play} />
            <% end %>

            <div :if={gate?(block)} class="mt-8">
              <.render_gate block={block} is_completed={block.id in @completed_ids} />
            </div>
          </div>
        <% end %>
      </div>

      <div
        :if={all_blocks_completed?(@visible_blocks, @completed_ids)}
        class="mt-20 pt-10 border-t border-base-300 animate-in fade-in slide-in-from-bottom-8 duration-1000"
      >
        <div class="bg-base-200/50 rounded-3xl p-10 text-center">
          <div class="size-16 bg-success/20 text-success rounded-full flex items-center justify-center mx-auto mb-6">
            <.icon name="hero-check-badge-solid" class="size-10" />
          </div>
          <h3 class="text-2xl font-black mb-2">{gettext("Lesson Completed!")}</h3>

          <%= if @next_section_id do %>
            <.link
              navigate={~p"/learn/courses/#{@course.id}/play/#{@next_section_id}"}
              class="btn btn-primary btn-lg px-12 mt-6 shadow-lg shadow-primary/20"
            >
              {gettext("Next Lesson")} <.icon name="hero-arrow-right" class="size-5 ml-2" />
            </.link>
          <% else %>
            <p class="text-base-content/60 mt-4 font-bold uppercase tracking-widest">
              {gettext("Course Completed!")}
            </p>
            <.link
              navigate={~p"/learn/courses/#{@course.id}"}
              class="btn btn-outline btn-lg px-12 mt-6"
            >
              {gettext("Back to Syllabus")}
            </.link>
          <% end %>
        </div>
      </div>

      <.modal
        :if={@course_map_open}
        id="course-map-modal"
        show={true}
        title={gettext("Course Map")}
        on_cancel={JS.push("close_course_map")}
      >
        <div class="max-h-[60vh] overflow-y-auto -mx-6 px-6 py-2">
          <.course_map_tree sections={@tree} active_section_id={@section.id} course_id={@course.id} />
        </div>
      </.modal>
    </div>
    """
  end

  def course_map_tree(assigns) do
    assigns = assign_new(assigns, :level, fn -> 0 end)

    ~H"""
    <div class="space-y-1">
      <div :for={section <- @sections}>
        <.link
          navigate={~p"/learn/courses/#{@course_id}/play/#{section.id}"}
          class={[
            "w-full justify-start px-3 py-2.5 rounded-lg flex items-center gap-3 transition-all group",
            @active_section_id == section.id && "bg-primary/10 text-primary",
            @active_section_id != section.id && "hover:bg-base-200 text-base-content/70"
          ]}
          style={"padding-left: #{(@level * 1.5) + 0.75}rem;"}
        >
          <%= if section.children == [] do %>
            <.icon
              name="hero-document-text"
              class={[
                "size-4 shrink-0 transition-colors",
                @active_section_id == section.id && "text-primary",
                @active_section_id != section.id && "text-base-content/30 group-hover:text-primary/70"
              ]}
            />
            <span class="text-sm font-medium truncate">{section.title}</span>
          <% else %>
            <.icon
              name="hero-folder"
              class={[
                "size-4 shrink-0 transition-colors",
                @active_section_id == section.id && "text-primary",
                @active_section_id != section.id && "text-base-content/40 group-hover:text-primary/70"
              ]}
            />
            <span class="text-xs uppercase tracking-widest font-black truncate">{section.title}</span>
          <% end %>
        </.link>

        <.course_map_tree
          :if={section.children != []}
          sections={section.children}
          active_section_id={@active_section_id}
          course_id={@course_id}
          level={@level + 1}
        />
      </div>
    </div>
    """
  end

  defp render_gate(%{block: %{completion_rule: %{type: :button}}} = assigns) do
    ~H"""
    <div class="py-2 border-t border-base-200">
      <%= if @is_completed do %>
        <div></div>
      <% else %>
        <button
          phx-click="complete_gate"
          phx-value-block-id={@block.id}
          class="btn btn-primary px-10 shadow-lg shadow-primary/20"
        >
          {@block.completion_rule.button_text || gettext("Continue")}
        </button>
      <% end %>
    </div>
    """
  end

  defp render_gate(assigns), do: ~H""

  @doc false
  defp schedule_next_unlock(socket, course_id) do
    now_unix = DateTime.utc_now() |> DateTime.to_unix()

    all_sections = Content.list_linear_lessons(course_id, :all)
    all_section_ids = Enum.map(all_sections, & &1.id)

    all_blocks = Content.list_blocks_by_section_ids(all_section_ids)

    all_rules =
      (all_sections ++ all_blocks)
      |> Enum.map(& &1.access_rules)
      |> Enum.reject(&is_nil/1)

    all_times =
      all_rules
      |> Enum.flat_map(&[&1.unlock_at, &1.lock_at])
      |> Enum.reject(&is_nil/1)

    future_unix_times =
      all_times
      |> Enum.map(&parse_to_unix/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(&(&1 > now_unix))
      |> Enum.sort()

    case List.first(future_unix_times) do
      nil ->
        socket

      target_unix ->
        raw_diff_ms = (target_unix - now_unix) * 1000 + 1000
        safe_diff_ms = min(raw_diff_ms, 86_400_000)

        Process.send_after(self(), :refresh_content, safe_diff_ms)
        socket
    end
  end

  defp parse_to_unix(%DateTime{} = dt), do: DateTime.to_unix(dt)

  defp parse_to_unix(%NaiveDateTime{} = ndt),
    do: DateTime.from_naive!(ndt, "Etc/UTC") |> DateTime.to_unix()

  defp parse_to_unix(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} ->
        DateTime.to_unix(dt)

      {:error, _} ->
        case NaiveDateTime.from_iso8601(str) do
          {:ok, ndt} -> DateTime.from_naive!(ndt, "Etc/UTC") |> DateTime.to_unix()
          _ -> nil
        end
    end
  end

  defp parse_to_unix(_), do: nil
end
