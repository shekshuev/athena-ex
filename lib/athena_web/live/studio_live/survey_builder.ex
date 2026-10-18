defmodule AthenaWeb.StudioLive.SurveyBuilder do
  @moduledoc """
  The survey builder: one centre column of question cards, edited in place.

  Modelled on Google Forms, and deliberately not on
  `AthenaWeb.StudioLive.Builder` (the course builder). A course is a tree of
  sections with access rules, gates and per-block telemetry, so it needs the
  three-pane structure/canvas/inspector layout. A survey is a short flat list
  of questions, so a single column where the expanded card *is* the editor
  needs no inspector and no structure sidebar.

  ## Why discrete events rather than one form

  Config edits arrive as small, targeted events (`update_list_item` carries
  the option's id; `add_list_item` carries only the list it belongs to).
  Index-keyed nested params would have meant fewer handlers but break as soon
  as a list is reordered or an item removed while someone is typing in
  another: the index that arrives no longer means what it meant when it was
  rendered.

  ## The structural lock

  Once a survey has any response - even an unfinished one - its questions and
  logic stop being editable, because changing them silently changes what the
  collected answers mean. The builder then renders read-only and offers
  "duplicate as new version" instead. `Athena.Surveys.Surveys.editable?/1`
  owns that rule; this LiveView only reflects it, and re-checks it on every
  mutating event rather than trusting the disabled state of a button.
  """

  use AthenaWeb, :live_view

  import AthenaWeb.SurveyComponents,
    only: [question: 1, question_editor: 1, logic_editor: 1, logic_report: 1, prompt_text: 1]

  alias Athena.Content
  alias Athena.Surveys
  alias Athena.Surveys.{AnswerParams, BranchClause, Flow, QuestionTypes, SurveyAnswer}

  on_mount {AthenaWeb.Hooks.Permission, "surveys.update"}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Surveys.get_survey(id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Survey not found."))
         |> push_navigate(to: ~p"/studio/surveys")}

      survey ->
        if Surveys.can_manage_survey?(socket.assigns.current_user, survey) do
          {:ok,
           socket
           |> assign(
             survey: survey,
             page_title: survey.title,
             expanded_id: nil,
             question_to_delete: nil,
             type_menu_for: nil,
             show_logic?: false,
             preview: nil
           )
           |> load_questions()}
        else
          {:ok,
           socket
           |> put_flash(:error, gettext("You cannot edit this survey."))
           |> push_navigate(to: ~p"/studio/surveys")}
        end
    end
  end

  # -- render ---------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.page_container size="narrow">
        <.sticky_header>
          <div class="flex flex-wrap items-start justify-between gap-4">
            <div class="min-w-0 flex-1">
              <.link
                navigate={~p"/studio/surveys"}
                class="mb-2 inline-flex items-center gap-1 text-sm text-base-content/60 hover:text-base-content"
              >
                <.icon name="hero-arrow-left" class="size-4" />
                {gettext("All surveys")}
              </.link>
              <form phx-change="rename_survey" phx-submit="rename_survey">
                <input
                  type="text"
                  id="survey-title"
                  name="title"
                  value={@survey.title}
                  phx-debounce="600"
                  aria-label={gettext("Survey title")}
                  class="input input-ghost w-full border-0 px-0 text-2xl font-display font-black focus:outline-none"
                />
              </form>
              <div class="mt-1 flex items-center gap-3 text-sm">
                <.badge tone={status_tone(@survey.status)}>{status_label(@survey.status)}</.badge>
                <span class="text-base-content/50">
                  {ngettext("%{count} question", "%{count} questions", length(@questions),
                    count: length(@questions)
                  )}
                </span>
                <span :if={@response_count > 0} class="text-base-content/50">
                  {ngettext("%{count} response", "%{count} responses", @response_count,
                    count: @response_count
                  )}
                </span>
              </div>
            </div>

            <div class="flex shrink-0 flex-wrap items-center gap-2">
              <.button
                :if={@response_count > 0}
                size="sm"
                variant="primary"
                navigate={~p"/studio/surveys/#{@survey.id}/results"}
                id="open-results"
              >
                <.icon name="hero-chart-bar" class="size-4" />
                {gettext("Results")}
              </.button>
              <.button
                :if={@questions != []}
                size="sm"
                phx-click="start_preview"
                id="start-preview"
              >
                <.icon name="hero-play" class="size-4" />
                {gettext("Preview")}
              </.button>
              <.button
                :if={@questions != []}
                size="sm"
                phx-click="toggle_logic"
                id="toggle-logic"
                class={[
                  "btn btn-outline btn-sm",
                  @logic_issues != [] && "btn-warning"
                ]}
              >
                <.icon
                  name={
                    if @logic_issues == [], do: "hero-check-circle", else: "hero-exclamation-triangle"
                  }
                  class="size-4"
                />
                {if @logic_issues == [],
                  do: gettext("Logic"),
                  else:
                    ngettext("%{count} logic issue", "%{count} logic issues", length(@logic_issues),
                      count: length(@logic_issues)
                    )}
              </.button>
              <.button
                :if={@survey.status == :draft}
                variant="primary"
                size="sm"
                phx-click="publish"
                id="publish-survey"
              >
                {gettext("Publish")}
              </.button>
              <.button
                :if={@survey.status == :published}
                size="sm"
                phx-click="close"
                id="close-survey"
              >
                {gettext("Close")}
              </.button>
              <.button
                :if={not @editable?}
                variant="primary"
                size="sm"
                phx-click="duplicate_as_version"
                id="duplicate-as-version"
              >
                {gettext("Duplicate as new version")}
              </.button>
            </div>
          </div>
        </.sticky_header>

        <%!-- A survey reaches students through a block in a course and
              nowhere else, so a published survey nobody has placed is a
              survey nobody can answer. Said out loud, because the symptom
              otherwise is silence: an author waits for responses that cannot
              arrive. --%>
        <div
          :if={@survey.status == :published and @usage == []}
          id="unused-banner"
          class="mb-6 flex gap-3 rounded-lg border border-warning/40 bg-warning/10 p-4"
        >
          <.icon name="hero-exclamation-triangle" class="size-5 shrink-0 text-warning" />
          <div class="text-sm">
            <p class="font-bold">{gettext("Nobody can answer this yet")}</p>
            <p class="mt-1 text-base-content/70">
              {gettext(
                "It is published, but it is not in any course. Open a course in the builder and add a Survey block pointing at it."
              )}
            </p>
          </div>
        </div>

        <div
          :if={@usage != []}
          id="usage-panel"
          class="mb-6 rounded-lg border border-base-300 bg-base-100 p-4"
        >
          <p class="mb-2 text-xs font-bold uppercase tracking-wide text-base-content/50">
            {gettext("Students reach it through")}
          </p>
          <ul class="space-y-1 text-sm">
            <li :for={place <- @usage} class="flex flex-wrap items-center gap-2">
              <.link
                navigate={
                  ~p"/studio/courses/#{place.course_id}/builder/sections/#{place.section_id}/blocks/#{place.block_id}"
                }
                class="link link-hover font-medium"
              >
                {place.course_title}
              </.link>
              <span class="text-base-content/40">/</span>
              <span class="text-base-content/60">{place.section_title}</span>
              <.badge :if={place.course_status != :published} tone="warning">
                {gettext("course not published")}
              </.badge>
            </li>
          </ul>
          <p :if={length(@usage) > 1} class="mt-2 text-xs text-base-content/50">
            {gettext("Editing it changes every one of these, and the answers stay one dataset.")}
          </p>
        </div>

        <div
          :if={not @editable?}
          id="locked-banner"
          class="mb-6 flex gap-3 rounded-lg border border-warning/40 bg-warning/10 p-4"
        >
          <.icon name="hero-lock-closed" class="size-5 shrink-0 text-warning" />
          <div class="text-sm">
            <p class="font-bold">{gettext("Questions are locked")}</p>
            <p class="mt-1 text-base-content/70">
              {gettext(
                "Students have already answered this survey. Changing its questions now would change what those answers mean, so make a new version instead."
              )}
            </p>
          </div>
        </div>

        <div
          :if={@show_logic? && @questions != []}
          id="logic-panel"
          class="mb-6 rounded-xl border border-base-300 bg-base-100 p-5"
        >
          <div class="mb-4 flex items-center justify-between">
            <h2 class="font-display font-bold">{gettext("Logic check")}</h2>
            <button
              type="button"
              phx-click="toggle_logic"
              class="btn btn-ghost btn-xs btn-square"
              aria-label={gettext("Close")}
            >
              <.icon name="hero-x-mark" class="size-4" />
            </button>
          </div>
          <.logic_report issues={@logic_issues} questions={@questions} branches={@branches} />
        </div>

        <.empty_state
          :if={@questions == []}
          icon="hero-clipboard-document-list"
          title={gettext("No questions yet")}
          description={gettext("Add your first question to start building the survey.")}
        />

        <ul
          :if={@questions != []}
          id="survey-questions"
          phx-hook="Sortable"
          data-event-name="reorder"
          class="space-y-4"
        >
          <li
            :for={{question, index} <- Enum.with_index(@questions, 1)}
            id={"question-#{question.id}"}
            data-id={question.id}
          >
            <.page_divider
              :if={new_page?(@questions, question)}
              page={question.page}
            />
            <.question_card
              question={question}
              index={index}
              questions={@questions}
              rules={Map.get(@branches, question.id, [])}
              expanded?={@expanded_id == question.id}
              type_menu?={@type_menu_for == question.id}
              editable?={@editable?}
            />
          </li>
        </ul>

        <div :if={@editable?} class="mt-6">
          <.type_picker label={gettext("Add question")} />
          <.button
            :if={@questions != []}
            size="sm"
            class="mt-3"
            phx-click="add_page_break"
            id="add-page-break"
          >
            <.icon name="hero-scissors" class="size-4" />
            {gettext("Add page break")}
          </.button>
        </div>
      </.page_container>

      <.preview_modal :if={@preview} preview={@preview} survey={@survey} />

      <.modal
        id="delete-question-modal"
        show={@question_to_delete != nil}
        title={gettext("Delete this question?")}
        description={gettext("Its branching rules will be removed too. This cannot be undone.")}
        on_cancel={JS.push("cancel_delete")}
        on_confirm={JS.push("confirm_delete")}
        confirm_label={gettext("Delete")}
        danger
      />
    </div>
    """
  end

  attr :question, :map, required: true
  attr :index, :integer, required: true
  attr :questions, :list, required: true
  attr :rules, :list, required: true
  attr :expanded?, :boolean, required: true
  attr :type_menu?, :boolean, required: true
  attr :editable?, :boolean, required: true

  defp question_card(assigns) do
    ~H"""
    <div
      data-active={to_string(@expanded?)}
      class={[
        "rounded-xl border bg-base-100 transition-all",
        if(@expanded?,
          do: "border-primary/40 shadow-md",
          else: "border-base-300 shadow-sm hover:border-base-content/20"
        )
      ]}
    >
      <div class="flex items-start gap-3 p-5">
        <span
          :if={@editable?}
          class="drag-handle mt-1 cursor-grab text-base-content/25 hover:text-base-content/60"
        >
          <.icon name="hero-bars-2" class="size-4" />
        </span>
        <span class="mt-0.5 w-5 shrink-0 text-sm font-black tabular-nums text-base-content/40">
          {@index}
        </span>

        <button
          type="button"
          phx-click="expand"
          phx-value-question_id={@question.id}
          id={"expand-#{@question.id}"}
          class="min-w-0 flex-1 text-left"
        >
          <span class="block truncate font-medium">
            {prompt_preview(@question)}
            <span :if={@question.required} class="text-error">*</span>
          </span>
          <span class="mt-0.5 flex items-center gap-1.5 text-xs text-base-content/50">
            <.icon name={type_icon(@question.type)} class="size-3.5" />
            {type_label(@question.type)}
          </span>
        </button>
      </div>

      <div :if={@expanded?} class="space-y-5 border-t border-base-200 px-5 pb-5 pt-5">
        <div :if={@editable?} class="relative">
          <button
            type="button"
            phx-click="open_type_menu"
            phx-value-question_id={@question.id}
            id={"type-menu-#{@question.id}"}
            class="btn btn-outline btn-sm gap-2"
          >
            <.icon name={type_icon(@question.type)} class="size-4" />
            {type_label(@question.type)}
            <.icon name="hero-chevron-down" class="size-3.5" />
          </button>
          <div
            :if={@type_menu?}
            class="absolute left-0 z-20 mt-1 w-64 rounded-lg border border-base-300 bg-base-100 p-1 shadow-xl"
          >
            <button
              :for={type <- QuestionTypes.all()}
              type="button"
              phx-click="change_type"
              phx-value-question_id={@question.id}
              phx-value-type={type}
              class={[
                "flex w-full items-center gap-2 rounded-md px-3 py-2 text-left text-sm transition-colors hover:bg-base-200",
                type == @question.type && "bg-primary/10 text-primary"
              ]}
            >
              <.icon name={type_icon(type)} class="size-4 shrink-0" />
              {type_label(type)}
            </button>
          </div>
        </div>

        <div>
          <label class="mb-1.5 block text-xs font-bold uppercase tracking-wide text-base-content/50">
            {gettext("Question")}
          </label>
          <div
            id={"prompt-editor-#{@question.id}"}
            phx-hook="TiptapEditor"
            phx-update="ignore"
            data-id={@question.id}
            data-readonly={to_string(not @editable?)}
            data-on-change="update_prompt"
            data-content={Jason.encode!(@question.body)}
            class="editor-wrapper prose prose-sm min-h-16 max-w-none rounded-lg border border-base-300 px-3 py-2"
          >
          </div>
        </div>

        <form phx-change="update_help_text">
          <input type="hidden" name="question_id" value={@question.id} />
          <.input
            type="text"
            name="help_text"
            value={@question.help_text}
            label={gettext("Helper text (optional)")}
            phx-debounce="500"
            disabled={not @editable?}
          />
        </form>

        <div :if={@editable?}>
          <.question_editor question={@question} />
        </div>
        <div :if={not @editable?} class="pointer-events-none opacity-60">
          <.question_editor question={@question} />
        </div>

        <%!-- Branching only has somewhere to go when a later question
              exists, so the section hides itself on the last one rather than
              offering a rule that could not do anything. --%>
        <div
          :if={@editable? && last_question?(@questions, @question)}
          class="border-t border-base-200 pt-4"
        >
          <p class="mb-3 text-xs font-bold uppercase tracking-wide text-base-content/50">
            {gettext("Branching")}
          </p>
          <.logic_editor question={@question} questions={@questions} rules={@rules} />
        </div>

        <div
          :if={@editable?}
          class="flex items-center justify-end gap-1 border-t border-base-200 pt-4"
        >
          <.button size="sm" variant="ghost" phx-click="collapse">
            {gettext("Done")}
          </.button>
          <button
            type="button"
            phx-click="duplicate_question"
            phx-value-question_id={@question.id}
            id={"duplicate-#{@question.id}"}
            class="btn btn-ghost btn-sm btn-square text-base-content/50"
            aria-label={gettext("Duplicate")}
          >
            <.icon name="hero-document-duplicate" class="size-4" />
          </button>
          <button
            type="button"
            phx-click="delete_click"
            phx-value-question_id={@question.id}
            id={"delete-#{@question.id}"}
            class="btn btn-ghost btn-sm btn-square text-base-content/50 hover:text-error"
            aria-label={gettext("Delete")}
          >
            <.icon name="hero-trash" class="size-4" />
          </button>
        </div>
      </div>
    </div>
    """
  end

  attr :preview, :map, required: true
  attr :survey, :map, required: true

  defp preview_modal(assigns) do
    ~H"""
    <div id="preview-modal" class="modal modal-open">
      <div class="modal-box max-w-2xl rounded-xl border border-base-300">
        <div class="mb-5 flex items-center justify-between">
          <div>
            <h3 class="font-display font-bold">{gettext("Preview")}</h3>
            <p class="text-xs text-base-content/50">
              {gettext("Nothing here is saved. Branching behaves exactly as it will for students.")}
            </p>
          </div>
          <button
            type="button"
            phx-click="close_preview"
            id="close-preview"
            class="btn btn-ghost btn-sm btn-square"
            aria-label={gettext("Close")}
          >
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </div>

        <div :if={@preview.finished?} id="preview-finished" class="py-8 text-center">
          <.icon name="hero-check-circle" class="mx-auto mb-3 size-12 text-success" />
          <p class="font-bold">{gettext("End of the survey")}</p>
          <p class="mt-1 text-sm text-base-content/60">
            {ngettext(
              "You answered %{count} question on this path.",
              "You answered %{count} questions on this path.",
              map_size(@preview.answers),
              count: map_size(@preview.answers)
            )}
          </p>
        </div>

        <div :if={!@preview.finished? && @preview.current}>
          <.question
            question={@preview.current}
            mode={:preview}
            answers={@preview.answers}
            event="preview_answer"
          />
        </div>

        <div class="modal-action">
          <.button
            :if={!@preview.finished? && @preview.history != []}
            size="sm"
            variant="ghost"
            phx-click="preview_back"
            id="preview-back"
          >
            {gettext("Back")}
          </.button>
          <.button size="sm" variant="ghost" phx-click="restart_preview" id="preview-restart">
            {gettext("Start over")}
          </.button>
          <.button
            :if={!@preview.finished?}
            size="sm"
            variant="primary"
            phx-click="preview_next"
            id="preview-next"
          >
            {gettext("Next")}
          </.button>
        </div>
      </div>
      <div class="modal-backdrop bg-black/50" phx-click="close_preview"></div>
    </div>
    """
  end

  defp last_question?(questions, question) do
    case List.last(questions) do
      nil -> false
      last -> last.id != question.id
    end
  end

  attr :label, :string, required: true

  defp type_picker(assigns) do
    ~H"""
    <div class="rounded-xl border border-dashed border-base-300 p-4">
      <p class="mb-3 text-xs font-bold uppercase tracking-wide text-base-content/50">{@label}</p>
      <div class="flex flex-wrap gap-2">
        <button
          :for={type <- QuestionTypes.all()}
          type="button"
          phx-click="add_question"
          phx-value-type={type}
          id={"add-#{type}"}
          class="btn btn-outline btn-sm gap-1.5"
        >
          <.icon name={type_icon(type)} class="size-4" />
          {type_label(type)}
        </button>
      </div>
    </div>
    """
  end

  attr :page, :integer, required: true

  defp page_divider(assigns) do
    ~H"""
    <div class="mb-4 flex items-center gap-3">
      <div class="h-px flex-1 bg-base-300"></div>
      <span class="text-xs font-bold uppercase tracking-widest text-base-content/40">
        {gettext("Page %{number}", number: @page + 1)}
      </span>
      <div class="h-px flex-1 bg-base-300"></div>
    </div>
    """
  end

  defp new_page?(questions, question) do
    case Enum.find_index(questions, &(&1.id == question.id)) do
      0 -> false
      nil -> false
      index -> Enum.at(questions, index - 1).page != question.page
    end
  end

  defp prompt_preview(question) do
    case prompt_text(question.body) do
      "" -> gettext("Untitled question")
      text -> text
    end
  end

  defp type_label(:single_choice), do: gettext("Single choice")
  defp type_label(:multiple_choice), do: gettext("Multiple choice")
  defp type_label(:dichotomous), do: gettext("Yes / no")
  defp type_label(:open_text), do: gettext("Open text")
  defp type_label(:numeric), do: gettext("Number")
  defp type_label(:scale), do: gettext("Scale")
  defp type_label(:multi_scale), do: gettext("Scale matrix")
  defp type_label(:matching), do: gettext("Matching")
  defp type_label(:ranking), do: gettext("Ranking")
  defp type_label(:nps), do: gettext("Recommendation (NPS)")

  defp type_icon(:single_choice), do: "hero-check-circle"
  defp type_icon(:multiple_choice), do: "hero-list-bullet"
  defp type_icon(:dichotomous), do: "hero-arrows-right-left"
  defp type_icon(:open_text), do: "hero-chat-bubble-bottom-center-text"
  defp type_icon(:numeric), do: "hero-hashtag"
  defp type_icon(:scale), do: "hero-adjustments-horizontal"
  defp type_icon(:multi_scale), do: "hero-table-cells"
  defp type_icon(:matching), do: "hero-link"
  defp type_icon(:ranking), do: "hero-bars-arrow-down"
  defp type_icon(:nps), do: "hero-hand-thumb-up"

  defp status_label(:draft), do: gettext("Draft")
  defp status_label(:published), do: gettext("Published")
  defp status_label(:closed), do: gettext("Closed")
  defp status_label(:archived), do: gettext("Archived")

  defp status_tone(:draft), do: "neutral"
  defp status_tone(:published), do: "success"
  defp status_tone(:closed), do: "warning"
  defp status_tone(:archived), do: "neutral"

  # -- questions ------------------------------------------------------------

  @impl true
  def handle_event("add_question", %{"type" => type}, socket) do
    with :ok <- ensure_editable(socket),
         {:ok, atom_type} <- known_type(type),
         {:ok, question} <- Surveys.add_question(socket.assigns.survey, atom_type) do
      {:noreply,
       socket
       |> assign(expanded_id: question.id)
       |> load_questions()}
    else
      {:error, reason} -> {:noreply, report(socket, reason)}
    end
  end

  def handle_event("expand", %{"question_id" => id}, socket) do
    expanded = if socket.assigns.expanded_id == id, do: nil, else: id
    {:noreply, assign(socket, expanded_id: expanded, type_menu_for: nil)}
  end

  def handle_event("collapse", _params, socket) do
    {:noreply, assign(socket, expanded_id: nil, type_menu_for: nil)}
  end

  def handle_event("open_type_menu", %{"question_id" => id}, socket) do
    menu = if socket.assigns.type_menu_for == id, do: nil, else: id
    {:noreply, assign(socket, type_menu_for: menu)}
  end

  def handle_event("change_type", %{"question_id" => id, "type" => type}, socket) do
    with :ok <- ensure_editable(socket),
         {:ok, atom_type} <- known_type(type),
         {:ok, question} <- fetch_question(socket, id),
         {:ok, _updated} <- Surveys.change_question_type(question, atom_type) do
      {:noreply,
       socket
       |> assign(type_menu_for: nil)
       |> maybe_warn_rules_dropped(question)
       |> load_questions()}
    else
      {:error, reason} -> {:noreply, report(socket, reason)}
    end
  end

  def handle_event("update_prompt", %{"id" => id, "content" => content}, socket) do
    update_question(socket, id, %{"body" => content})
  end

  def handle_event("update_help_text", %{"question_id" => id, "help_text" => text}, socket) do
    update_question(socket, id, %{"help_text" => text})
  end

  def handle_event("toggle_required", %{"question_id" => id}, socket) do
    case fetch_question(socket, id) do
      {:ok, question} ->
        update_question(socket, id, %{"required" => not question.required})

      {:error, reason} ->
        {:noreply, report(socket, reason)}
    end
  end

  def handle_event("duplicate_question", %{"question_id" => id}, socket) do
    with :ok <- ensure_editable(socket),
         {:ok, question} <- fetch_question(socket, id),
         {:ok, copy} <- Surveys.duplicate_question(question) do
      {:noreply,
       socket
       |> assign(expanded_id: copy.id)
       |> load_questions()}
    else
      {:error, reason} -> {:noreply, report(socket, reason)}
    end
  end

  def handle_event("delete_click", %{"question_id" => id}, socket) do
    case fetch_question(socket, id) do
      {:ok, question} -> {:noreply, assign(socket, question_to_delete: question)}
      {:error, reason} -> {:noreply, report(socket, reason)}
    end
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, question_to_delete: nil)}
  end

  def handle_event("confirm_delete", _params, socket) do
    question = socket.assigns.question_to_delete

    with :ok <- ensure_editable(socket),
         %{} <- question,
         {:ok, _deleted} <- Surveys.delete_question(question) do
      {:noreply,
       socket
       |> assign(question_to_delete: nil, expanded_id: nil)
       |> put_flash(:info, gettext("Question deleted."))
       |> load_questions()}
    else
      nil -> {:noreply, assign(socket, question_to_delete: nil)}
      {:error, reason} -> {:noreply, socket |> assign(question_to_delete: nil) |> report(reason)}
    end
  end

  # SortableJS reports only the move, not the resulting order, so the new
  # order is computed from the list this LiveView already holds.
  def handle_event("reorder", %{"id" => id, "new_index" => new_index}, socket) do
    case ensure_editable(socket) do
      :ok ->
        ordered =
          socket.assigns.questions
          |> Enum.map(& &1.id)
          |> List.delete(id)
          |> List.insert_at(new_index, id)

        case Surveys.reorder_questions(socket.assigns.survey.id, ordered) do
          {:ok, _questions} -> {:noreply, load_questions(socket)}
          {:error, reason} -> {:noreply, report(socket, reason)}
        end

      {:error, reason} ->
        {:noreply, report(socket, reason)}
    end
  end

  def handle_event("add_page_break", _params, socket) do
    case ensure_editable(socket) do
      :ok ->
        # A page break is not a row of its own: it is the page number of every
        # question from here on. Modelling it as data rather than as a marker
        # question keeps `Flow` free of a type that is not a question.
        {:noreply, bump_last_page(socket)}

      {:error, reason} ->
        {:noreply, report(socket, reason)}
    end
  end

  # -- config ---------------------------------------------------------------

  def handle_event("update_config", %{"question_id" => id} = params, socket) do
    config = Map.get(params, "config", %{})

    case fetch_question(socket, id) do
      {:ok, question} ->
        update_question(socket, id, %{"config" => Map.merge(question.config, config)})

      {:error, reason} ->
        {:noreply, report(socket, reason)}
    end
  end

  def handle_event("toggle_config_flag", %{"question_id" => id, "key" => key}, socket) do
    case fetch_question(socket, id) do
      {:ok, question} ->
        flipped = not truthy?(question.config[key])
        update_question(socket, id, %{"config" => Map.put(question.config, key, flipped)})

      {:error, reason} ->
        {:noreply, report(socket, reason)}
    end
  end

  def handle_event("add_list_item", %{"question_id" => id, "list_key" => key}, socket) do
    case fetch_question(socket, id) do
      {:ok, question} ->
        existing = List.wrap(question.config[key])
        item = new_list_item(key, length(existing) + 1)

        update_question(socket, id, %{
          "config" => Map.put(question.config, key, existing ++ [item])
        })

      {:error, reason} ->
        {:noreply, report(socket, reason)}
    end
  end

  def handle_event(
        "remove_list_item",
        %{"question_id" => id, "list_key" => key, "item_id" => item_id},
        socket
      ) do
    case fetch_question(socket, id) do
      {:ok, question} ->
        remaining = question.config |> config_list(key) |> Enum.reject(&(&1["id"] == item_id))

        update_question(socket, id, %{"config" => Map.put(question.config, key, remaining)})

      {:error, reason} ->
        {:noreply, report(socket, reason)}
    end
  end

  def handle_event(
        "update_list_item",
        %{
          "question_id" => id,
          "list_key" => key,
          "item_id" => item_id,
          "field" => field,
          "text" => text
        },
        socket
      ) do
    case fetch_question(socket, id) do
      {:ok, question} ->
        updated = put_item_field(config_list(question.config, key), item_id, field, text)

        update_question(socket, id, %{"config" => Map.put(question.config, key, updated)})

      {:error, reason} ->
        {:noreply, report(socket, reason)}
    end
  end

  # -- logic ----------------------------------------------------------------

  def handle_event("toggle_logic", _params, socket) do
    {:noreply, assign(socket, show_logic?: not socket.assigns.show_logic?)}
  end

  def handle_event("add_rule", %{"question_id" => id}, socket) do
    with :ok <- ensure_editable(socket),
         {:ok, question} <- fetch_question(socket, id),
         {:ok, _rule} <-
           Surveys.add_branch(socket.assigns.survey, question, default_rule(question)) do
      {:noreply, load_questions(socket)}
    else
      {:error, reason} -> {:noreply, report(socket, reason)}
    end
  end

  def handle_event("delete_rule", %{"rule_id" => rule_id}, socket) do
    with :ok <- ensure_editable(socket),
         {:ok, rule} <- fetch_rule(socket, rule_id),
         {:ok, _deleted} <- Surveys.delete_branch(rule) do
      {:noreply, load_questions(socket)}
    else
      {:error, reason} -> {:noreply, report(socket, reason)}
    end
  end

  def handle_event("update_rule", %{"rule_id" => rule_id} = params, socket) do
    attrs = Map.take(params, ["action", "target_question_id", "target_page"])

    save_rule(socket, rule_id, attrs)
  end

  def handle_event("reorder_rules", %{"id" => rule_id, "new_index" => new_index} = params, socket) do
    with :ok <- ensure_editable(socket),
         {:ok, question} <- fetch_question(socket, params["questionId"] || params["question_id"]) do
      ordered =
        question.id
        |> rules_for(socket)
        |> Enum.map(& &1.id)
        |> List.delete(rule_id)
        |> List.insert_at(new_index, rule_id)

      case Surveys.reorder_branches(question.id, ordered) do
        {:ok, _rules} -> {:noreply, load_questions(socket)}
        {:error, reason} -> {:noreply, report(socket, reason)}
      end
    else
      {:error, reason} -> {:noreply, report(socket, reason)}
    end
  end

  def handle_event("toggle_rule_logic", %{"rule_id" => rule_id}, socket) do
    case fetch_rule(socket, rule_id) do
      {:ok, rule} ->
        flipped = if rule.condition.logic == :and, do: :or, else: :and

        save_rule(socket, rule_id, %{
          "condition" => %{
            "logic" => flipped,
            "clauses" => Enum.map(rule.condition.clauses, &clause_to_params/1)
          }
        })

      {:error, reason} ->
        {:noreply, report(socket, reason)}
    end
  end

  def handle_event("add_clause", %{"rule_id" => rule_id}, socket) do
    case fetch_rule(socket, rule_id) do
      {:ok, rule} ->
        owner = Enum.find(socket.assigns.questions, &(&1.id == rule.question_id))

        save_rule(socket, rule_id, %{
          "condition" => %{
            "logic" => rule.condition.logic,
            "clauses" =>
              Enum.map(rule.condition.clauses, &clause_to_params/1) ++
                [BranchClause.new(%{"question_id" => owner && owner.id})]
          }
        })

      {:error, reason} ->
        {:noreply, report(socket, reason)}
    end
  end

  def handle_event("remove_clause", %{"rule_id" => rule_id, "clause_id" => clause_id}, socket) do
    case fetch_rule(socket, rule_id) do
      {:ok, rule} ->
        remaining =
          rule.condition.clauses
          |> Enum.reject(&(&1.id == clause_id))
          |> Enum.map(&clause_to_params/1)

        save_rule(socket, rule_id, %{
          "condition" => %{"logic" => rule.condition.logic, "clauses" => remaining}
        })

      {:error, reason} ->
        {:noreply, report(socket, reason)}
    end
  end

  def handle_event(
        "update_clause",
        %{"rule_id" => rule_id, "clause_id" => clause_id} = params,
        socket
      ) do
    case fetch_rule(socket, rule_id) do
      {:ok, rule} ->
        clauses = rebuild_clauses(rule, clause_id, params, socket)

        save_rule(socket, rule_id, %{
          "condition" => %{"logic" => rule.condition.logic, "clauses" => clauses}
        })

      {:error, reason} ->
        {:noreply, report(socket, reason)}
    end
  end

  # -- preview --------------------------------------------------------------

  def handle_event("start_preview", _params, socket) do
    {:noreply, assign(socket, preview: fresh_preview(socket))}
  end

  def handle_event("close_preview", _params, socket) do
    {:noreply, assign(socket, preview: nil)}
  end

  def handle_event("restart_preview", _params, socket) do
    {:noreply, assign(socket, preview: fresh_preview(socket))}
  end

  def handle_event("preview_answer", %{"question_id" => id} = params, socket) do
    preview = socket.assigns.preview

    with %{} <- preview,
         {:ok, question} <- fetch_question(socket, id) do
      {:noreply, assign(socket, preview: record_preview_answer(preview, question, params))}
    else
      _ -> {:noreply, socket}
    end
  end

  # Ranking is the one type that does not post a form: SortableJS reports a
  # move, and the resulting order is computed from what is already on screen.
  # The dataset arrives camelCased, hence "questionId".
  def handle_event(
        "survey_rank",
        %{"questionId" => question_id, "id" => item_id, "new_index" => new_index},
        socket
      ) do
    preview = socket.assigns.preview

    with %{} <- preview,
         {:ok, question} <- fetch_question(socket, question_id) do
      reordered =
        preview
        |> current_rank_order(question)
        |> List.delete(item_id)
        |> List.insert_at(new_index, item_id)

      params = %{"value" => %{"choice_ids" => reordered}}

      {:noreply, assign(socket, preview: record_preview_answer(preview, question, params))}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("preview_next", _params, socket) do
    preview = socket.assigns.preview

    case Flow.next_question(preview.flow, preview.current, preview.answers) do
      :end ->
        {:noreply, assign(socket, preview: %{preview | finished?: true})}

      {:question, next} ->
        {:noreply,
         assign(socket,
           preview: %{
             preview
             | current: next,
               history: [preview.current.id | preview.history]
           }
         )}
    end
  end

  def handle_event("preview_back", _params, socket) do
    preview = socket.assigns.preview

    case Flow.previous(preview.flow, preview.history) do
      :none ->
        {:noreply, socket}

      {:question, previous, rest} ->
        {:noreply, assign(socket, preview: %{preview | current: previous, history: rest})}
    end
  end

  # -- survey lifecycle -----------------------------------------------------

  def handle_event("rename_survey", %{"title" => title}, socket) do
    case Surveys.update_survey(socket.assigns.survey, %{"title" => title}) do
      {:ok, survey} -> {:noreply, assign(socket, survey: survey, page_title: survey.title)}
      {:error, _changeset} -> {:noreply, report(socket, :invalid_title)}
    end
  end

  def handle_event("publish", _params, socket) do
    case Surveys.publish_survey(socket.assigns.survey) do
      {:ok, survey} ->
        {:noreply,
         socket
         |> assign(survey: survey)
         |> put_flash(:info, gettext("Survey published. Students can now answer it."))}

      {:error, reason} ->
        {:noreply, report(socket, reason)}
    end
  end

  def handle_event("close", _params, socket) do
    case Surveys.close_survey(socket.assigns.survey) do
      {:ok, survey} ->
        {:noreply,
         socket
         |> assign(survey: survey)
         |> put_flash(:info, gettext("Survey closed to new responses."))}

      {:error, reason} ->
        {:noreply, report(socket, reason)}
    end
  end

  def handle_event("duplicate_as_version", _params, socket) do
    case Surveys.duplicate_as_version(socket.assigns.survey, socket.assigns.current_user) do
      {:ok, copy} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Copied to a new draft you can edit."))
         |> push_navigate(to: ~p"/studio/surveys/#{copy.id}/builder")}

      {:error, reason} ->
        {:noreply, report(socket, reason)}
    end
  end

  # -- helpers --------------------------------------------------------------

  defp update_question(socket, id, attrs) do
    with :ok <- ensure_editable(socket),
         {:ok, question} <- fetch_question(socket, id),
         {:ok, _updated} <- Surveys.update_question(question, attrs) do
      {:noreply, load_questions(socket)}
    else
      {:error, reason} -> {:noreply, report(socket, reason)}
    end
  end

  defp fetch_question(socket, id) do
    case Enum.find(socket.assigns.questions, &(&1.id == id)) do
      nil -> {:error, :question_not_found}
      question -> {:ok, question}
    end
  end

  # Re-checked on every mutating event rather than relying on a disabled
  # button: the lock protects already-collected data, and a stale tab must
  # not be able to edit around it.
  defp ensure_editable(socket) do
    if Surveys.survey_editable?(socket.assigns.survey), do: :ok, else: {:error, :locked}
  end

  defp known_type(type) do
    case Enum.find(QuestionTypes.all(), &(to_string(&1) == type)) do
      nil -> {:error, :unknown_type}
      found -> {:ok, found}
    end
  end

  defp load_questions(socket) do
    survey = socket.assigns.survey
    questions = Surveys.list_questions(survey.id)
    branches = Surveys.branches_by_question(survey.id)

    flow = Flow.build(survey, questions, branches |> Map.values() |> List.flatten())

    assign(socket,
      questions: questions,
      usage: Content.courses_using_survey(survey.id),
      branches: branches,
      logic_issues: Flow.validate_graph(flow),
      editable?: Surveys.survey_editable?(survey),
      response_count: length(Surveys.list_responses(survey.id))
    )
  end

  defp bump_last_page(socket) do
    case List.last(socket.assigns.questions) do
      nil ->
        report(socket, :no_questions)

      last ->
        case Surveys.add_question(socket.assigns.survey, :open_text, %{"page" => last.page + 1}) do
          {:ok, question} -> socket |> assign(expanded_id: question.id) |> load_questions()
          {:error, reason} -> report(socket, reason)
        end
    end
  end

  defp maybe_warn_rules_dropped(socket, question) do
    if Surveys.list_branches_for_question(question.id) == [] do
      socket
    else
      put_flash(
        socket,
        :info,
        gettext("Branching rules that tested this question were removed.")
      )
    end
  end

  defp new_list_item("pairs", n),
    do: %{"id" => Ecto.UUID.generate(), "left" => "Left #{n}", "right" => "Right #{n}"}

  defp new_list_item("rows", n), do: %{"id" => Ecto.UUID.generate(), "text" => "Item #{n}"}
  defp new_list_item(_key, n), do: %{"id" => Ecto.UUID.generate(), "text" => "Option #{n}"}

  defp config_list(config, key), do: List.wrap(config[key])

  # Addressed by id, not by position: a list index shifts while someone is
  # typing in a sibling and no longer means what it meant when it was
  # rendered.
  defp put_item_field(items, item_id, field, text) do
    Enum.map(items, fn item ->
      if item["id"] == item_id, do: Map.put(item, field, text), else: item
    end)
  end

  # The whole clause list is always written back, because `BranchClause` has
  # no primary key and Ecto cannot match a posted clause to a stored one -
  # see `Athena.Surveys.BranchCondition`.
  defp rebuild_clauses(rule, clause_id, params, socket) do
    Enum.map(rule.condition.clauses, fn clause ->
      if clause.id == clause_id do
        rebuild_clause(clause, params, socket)
      else
        clause_to_params(clause)
      end
    end)
  end

  # -- logic helpers --------------------------------------------------------

  defp fetch_rule(socket, rule_id) do
    case Enum.find(all_rules(socket), &(&1.id == rule_id)) do
      nil -> {:error, :rule_not_found}
      rule -> {:ok, rule}
    end
  end

  defp all_rules(socket), do: socket.assigns.branches |> Map.values() |> List.flatten()

  defp rules_for(question_id, socket), do: Map.get(socket.assigns.branches, question_id, [])

  defp save_rule(socket, rule_id, attrs) do
    with :ok <- ensure_editable(socket),
         {:ok, rule} <- fetch_rule(socket, rule_id),
         {:ok, _updated} <- Surveys.update_branch(rule, attrs) do
      {:noreply, load_questions(socket)}
    else
      {:error, reason} -> {:noreply, report(socket, reason)}
    end
  end

  # A new rule starts as "if this question was answered, end the survey": both
  # halves are valid immediately, so the rule saves and the author edits it in
  # place rather than filling a blank form before anything exists.
  defp default_rule(question) do
    %{
      "action" => "end_survey",
      "condition" => %{
        "logic" => "and",
        "clauses" => [BranchClause.new(%{"question_id" => question.id})]
      }
    }
  end

  defp clause_to_params(clause) do
    %{
      "id" => clause.id,
      "question_id" => clause.question_id,
      "op" => clause.op,
      "value" => clause.value
    }
  end

  # The browser posts whatever inputs were on screen when the author changed
  # something. Two of those changes invalidate the operand that came with
  # them: picking a different question to test, and picking an operator that
  # needs a different kind of operand. In both cases the operand is reset
  # rather than carried over - `Flow` reads a mismatched operand as false, so
  # keeping it would leave a rule that silently never matches.
  defp rebuild_clause(clause, params, socket) do
    question_id = params["question_id"] || clause.question_id
    op = parse_op(params["op"]) || clause.op

    tested = Enum.find(socket.assigns.questions, &(&1.id == question_id))

    value =
      cond do
        is_nil(tested) -> %{}
        # A different question means a different set of possible answers, so
        # whatever operand came with the old one is meaningless.
        question_id != clause.question_id -> %{}
        # Casting for the operator now selected is enough on its own: an
        # operand belonging to a different kind simply does not survive the
        # cast. Clearing it outright instead would make an operator change
        # impossible, since the browser always posts the previous inputs on
        # the round-trip that re-renders them.
        true -> cast_operand(op, tested, params["value"] || %{})
      end

    %{"id" => clause.id, "question_id" => question_id, "op" => op, "value" => value}
  end

  defp parse_op(nil), do: nil

  defp parse_op(string) do
    Enum.find(BranchClause.operators(), &(to_string(&1) == string))
  end

  defp cast_operand(op, tested, posted) do
    measurement = QuestionTypes.measurement(tested.type)

    base =
      case BranchClause.operand_kind(op, measurement) do
        :none -> %{}
        :number -> put_parsed_number(%{}, posted, "number")
        :range -> %{} |> put_parsed_number(posted, "from") |> put_parsed_number(posted, "to")
        :choices -> %{"choice_ids" => posted_choice_ids(posted)}
        :text -> %{"text" => posted["text"] || ""}
        :texts -> %{"texts" => split_texts(posted["texts"])}
      end

    maybe_put_row(base, tested, posted)
  end

  # Carried alongside the operand, not instead of it: a matrix clause needs
  # both the row it tests and the value it compares against.
  defp maybe_put_row(value, %{type: :multi_scale}, posted) do
    case posted["row_id"] do
      row when is_binary(row) and row != "" -> Map.put(value, "row_id", row)
      _ -> value
    end
  end

  defp maybe_put_row(value, _tested, _posted), do: value

  defp put_parsed_number(acc, posted, key) do
    case AnswerParams.parse_number(posted[key]) do
      {:ok, number} -> Map.put(acc, key, number)
      :error -> acc
    end
  end

  defp posted_choice_ids(posted) do
    posted
    |> Map.get("choice_ids", [])
    |> List.wrap()
    |> Enum.reject(&(&1 in [nil, ""]))
  end

  defp split_texts(nil), do: []

  defp split_texts(string) do
    string |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  end

  # -- preview helpers ------------------------------------------------------

  defp fresh_preview(socket) do
    flow =
      Flow.build(socket.assigns.survey, socket.assigns.questions, all_rules(socket))

    %{
      flow: flow,
      current: Flow.first_question(flow),
      answers: %{},
      history: [],
      finished?: false
    }
  end

  defp current_rank_order(preview, question) do
    case Map.get(preview.answers, {question.id, ""}) do
      %{value_choice_ids: ids} when is_list(ids) and ids != [] ->
        ids

      _ ->
        question.config |> config_list("items") |> Enum.map(& &1["id"])
    end
  end

  # The preview derives its answers through the real answer changeset and then
  # throws the struct away instead of inserting it. That is what makes the
  # preview trustworthy: the projections a condition is evaluated against are
  # produced by exactly the code that produces them in the player, so a branch
  # that fires here fires there.
  defp record_preview_answer(preview, question, params) do
    value = AnswerParams.cast(question.type, params)

    changeset =
      SurveyAnswer.changeset(
        %SurveyAnswer{},
        %{
          response_id: Ecto.UUID.generate(),
          question_id: question.id,
          value: value
        },
        question.type
      )

    if changeset.valid? do
      answer = Ecto.Changeset.apply_changes(changeset)
      %{preview | answers: Map.put(preview.answers, {question.id, answer.row_key}, answer)}
    else
      preview
    end
  end

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_value), do: false

  defp report(socket, :locked),
    do:
      put_flash(
        socket,
        :error,
        gettext("This survey already has responses, so its questions can no longer change.")
      )

  defp report(socket, :no_questions),
    do: put_flash(socket, :error, gettext("Add a question first."))

  defp report(socket, :unknown_type),
    do: put_flash(socket, :error, gettext("Unknown question type."))

  defp report(socket, :rule_not_found),
    do: put_flash(socket, :error, gettext("That rule no longer exists."))

  defp report(socket, :all_at_once),
    do:
      put_flash(
        socket,
        :error,
        gettext("Switch to one question per page before adding branching rules.")
      )

  defp report(socket, :question_not_found),
    do: put_flash(socket, :error, gettext("That question no longer exists."))

  defp report(socket, :invalid_title),
    do: put_flash(socket, :error, gettext("A survey needs a title."))

  defp report(socket, %Ecto.Changeset{} = changeset),
    do: put_flash(socket, :error, changeset_message(changeset))

  defp report(socket, _reason),
    do: put_flash(socket, :error, gettext("That change could not be saved."))

  # `traverse_errors` nests: an embed's errors arrive as a map (or a list of
  # maps for `embeds_many`), not as a flat list of messages.
  defp changeset_message(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
    |> flatten_messages()
    |> Enum.join("; ")
  end

  defp flatten_messages(errors) when is_map(errors) do
    Enum.flat_map(errors, fn {field, nested} ->
      Enum.map(flatten_messages(nested), &"#{field}: #{&1}")
    end)
  end

  defp flatten_messages(errors) when is_list(errors) do
    Enum.flat_map(errors, fn
      message when is_binary(message) -> [message]
      nested -> flatten_messages(nested)
    end)
  end

  defp flatten_messages(message) when is_binary(message), do: [message]
  defp flatten_messages(_other), do: []
end
