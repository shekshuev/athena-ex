defmodule AthenaWeb.StudioLive.Surveys do
  @moduledoc """
  The survey list: every survey the current user may read, with its status and
  response counts, plus create/rename/archive.

  Authoring lives in `AthenaWeb.StudioLive.SurveyBuilder` and results will
  attach here (the list is where someone goes to ask "what did students
  say"), which is why both sit under `/studio` rather than splitting
  authoring from reading across two sections of the app.

  Scoping is `Athena.Identity.Acl.scope_query/3` inside
  `Athena.Surveys.Surveys.list_for_user/3`, not re-derived here, so a role
  carrying `surveys.read` with the `own_only` policy sees only its own.
  """

  use AthenaWeb, :live_view

  alias Athena.Content
  alias Athena.Identity
  alias Athena.Surveys
  alias Athena.Surveys.Survey

  on_mount {AthenaWeb.Hooks.Permission, "surveys.read"}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: gettext("Surveys"),
       survey_to_archive: nil,
       show_archived?: false
     )
     |> stream(:surveys, [])}
  end

  @impl true
  def handle_params(params, _url, socket) do
    search = Map.get(params, "search", "")
    show_archived? = Map.get(params, "archived") == "1"

    flop_params = with_search(params, search)

    case Surveys.list_surveys_for_user(socket.assigns.current_user, flop_params,
           include_archived: show_archived?
         ) do
      {:ok, {surveys, meta}} ->
        {:noreply,
         socket
         |> assign(
           meta: meta,
           search: search,
           show_archived?: show_archived?,
           counts: response_counts(surveys),
           question_counts: question_counts(surveys),
           usage_counts: Content.survey_usage_counts(Enum.map(surveys, & &1.id)),
           live_action: socket.assigns.live_action,
           form: new_form()
         )
         |> stream(:surveys, surveys, reset: true)}

      {:error, _meta} ->
        {:noreply, push_patch(socket, to: ~p"/studio/surveys")}
    end
  end

  defp with_search(params, ""), do: Map.delete(params, "filters")

  defp with_search(params, search) do
    Map.put(params, "filters", %{
      "0" => %{"field" => "title", "op" => "ilike_and", "value" => search}
    })
  end

  # One query per survey would be N+1 on a list page, so both counts are
  # gathered in a single grouped query each.
  defp response_counts(surveys),
    do: Surveys.count_responses_for(Enum.map(surveys, & &1.id))

  defp question_counts(surveys),
    do: Surveys.count_questions_for(Enum.map(surveys, & &1.id))

  defp new_form, do: to_form(Surveys.change_survey(%Survey{}), as: :survey)

  # -- events ---------------------------------------------------------------

  @impl true
  def handle_event("search", %{"search" => search}, socket) do
    {:noreply, push_patch(socket, to: path_with(socket, %{"search" => search, "page" => 1}))}
  end

  def handle_event("update_page_size", %{"page_size" => size}, socket) do
    {:noreply, push_patch(socket, to: path_with(socket, %{"page_size" => size, "page" => 1}))}
  end

  def handle_event("toggle_archived", _params, socket) do
    archived = if socket.assigns.show_archived?, do: nil, else: "1"
    {:noreply, push_patch(socket, to: path_with(socket, %{"archived" => archived, "page" => 1}))}
  end

  def handle_event("create", %{"survey" => params}, socket) do
    if Identity.can?(socket.assigns.current_user, "surveys.create") do
      case Surveys.create_survey(socket.assigns.current_user, params) do
        {:ok, survey} ->
          {:noreply, push_navigate(socket, to: ~p"/studio/surveys/#{survey.id}/builder")}

        {:error, changeset} ->
          {:noreply, assign(socket, form: to_form(changeset, as: :survey))}
      end
    else
      {:noreply, put_flash(socket, :error, gettext("You cannot create surveys."))}
    end
  end

  def handle_event("validate", %{"survey" => params}, socket) do
    form =
      %Survey{}
      |> Surveys.change_survey(params)
      |> Map.put(:action, :validate)
      |> to_form(as: :survey)

    {:noreply, assign(socket, form: form)}
  end

  def handle_event("archive_click", %{"id" => id}, socket) do
    with {:ok, survey} <- authorized(socket, id, "surveys.delete") do
      {:noreply, assign(socket, survey_to_archive: survey)}
    else
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("cancel_archive", _params, socket) do
    {:noreply, assign(socket, survey_to_archive: nil)}
  end

  def handle_event("confirm_archive", _params, socket) do
    survey = socket.assigns.survey_to_archive

    with %Survey{} <- survey,
         {:ok, _archived} <- Surveys.archive_survey(survey) do
      {:noreply,
       socket
       |> assign(survey_to_archive: nil)
       |> put_flash(:info, gettext("Survey archived. Its responses are kept."))
       |> stream_delete(:surveys, survey)}
    else
      nil ->
        {:noreply, assign(socket, survey_to_archive: nil)}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(survey_to_archive: nil)
         |> put_flash(:error, gettext("Could not archive that survey."))}
    end
  end

  def handle_event("restore", %{"id" => id}, socket) do
    with {:ok, survey} <- authorized(socket, id, "surveys.update"),
         {:ok, restored} <- Surveys.update_survey(survey, %{"status" => :draft}) do
      {:noreply,
       socket
       |> put_flash(:info, gettext("Survey restored as a draft."))
       |> stream_insert(:surveys, restored)}
    else
      {:error, message} when is_binary(message) ->
        {:noreply, put_flash(socket, :error, message)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("Could not restore that survey."))}
    end
  end

  # Permission *and* the record-level `own_only` policy: a role holding
  # `surveys.update` with that policy must be refused on someone else's
  # survey, not merely kept off the screen.
  defp authorized(socket, id, permission) do
    user = socket.assigns.current_user

    case Surveys.get_survey(id) do
      nil ->
        {:error, gettext("That survey no longer exists.")}

      survey ->
        if Identity.can?(user, permission, survey) do
          {:ok, survey}
        else
          {:error, gettext("You cannot change that survey.")}
        end
    end
  end

  defp path_with(socket, overrides),
    do: build_path(socket.assigns.search, socket.assigns.show_archived?, overrides)

  # Shared by the search/archive toggles and by the paginator, so every way of
  # changing the list preserves the other filters rather than resetting them.
  defp build_path(search, show_archived?, overrides) do
    params =
      %{"search" => search}
      |> then(fn base -> if show_archived?, do: Map.put(base, "archived", "1"), else: base end)
      |> Map.merge(overrides)
      |> Enum.reject(fn {_key, value} -> value in [nil, "", 1] end)
      |> Map.new()

    ~p"/studio/surveys?#{params}"
  end

  # -- render ---------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.page_container size="standard">
        <.sticky_header>
          <div class="flex flex-wrap items-end justify-between gap-4">
            <div>
              <h1 class="font-display text-2xl font-black">{gettext("Surveys")}</h1>
              <p class="mt-1 text-sm text-base-content/60">
                {gettext(
                  "Collect feedback from students. Answers from a cohort stay grouped by cohort."
                )}
              </p>
            </div>
            <.button
              :if={Identity.can?(@current_user, "surveys.create")}
              variant="primary"
              size="sm"
              navigate={~p"/studio/surveys/new"}
              id="new-survey"
            >
              <.icon name="hero-plus" class="size-4" />
              {gettext("New survey")}
            </.button>
          </div>
        </.sticky_header>

        <div class="mb-6 flex flex-wrap items-center gap-3">
          <form phx-change="search" phx-submit="search" class="min-w-0 flex-1">
            <label class="input input-bordered flex items-center gap-2">
              <.icon name="hero-magnifying-glass" class="size-4 text-base-content/40" />
              <input
                type="text"
                name="search"
                value={@search}
                phx-debounce="300"
                placeholder={gettext("Search surveys")}
                class="grow"
              />
            </label>
          </form>
          <label class="flex cursor-pointer items-center gap-2 text-sm">
            <input
              type="checkbox"
              checked={@show_archived?}
              phx-click="toggle_archived"
              id="toggle-archived"
              class="toggle toggle-sm"
            />
            {gettext("Show archived")}
          </label>
        </div>

        <div id="surveys" phx-update="stream" class="space-y-3">
          <%!-- Inside phx-update="stream" every child needs an id, and the
                empty state only shows while it is the stream's only child. --%>
          <div id="surveys-empty" class="hidden only:block">
            <.empty_state
              icon="hero-clipboard-document-list"
              title={gettext("No surveys yet")}
              description={gettext("Create a survey to ask students how a course is going.")}
            />
          </div>
          <div
            :for={{dom_id, survey} <- @streams.surveys}
            id={dom_id}
            class="flex flex-wrap items-center gap-4 rounded-xl border border-base-300 bg-base-100 p-5 transition-colors hover:border-base-content/20"
          >
            <div class="min-w-0 flex-1">
              <.link
                navigate={~p"/studio/surveys/#{survey.id}/builder"}
                class="font-bold hover:text-primary"
              >
                {survey.title}
              </.link>
              <div class="mt-1 flex flex-wrap items-center gap-3 text-xs text-base-content/50">
                <.badge tone={status_tone(survey.status)}>{status_label(survey.status)}</.badge>
                <span>
                  {ngettext(
                    "%{count} question",
                    "%{count} questions",
                    Map.get(@question_counts, survey.id, 0),
                    count: Map.get(@question_counts, survey.id, 0)
                  )}
                </span>
                <span>
                  {ngettext(
                    "%{count} response",
                    "%{count} responses",
                    Map.get(@counts, survey.id, 0),
                    count: Map.get(@counts, survey.id, 0)
                  )}
                </span>
                <%!-- A published survey in no course is a survey nobody can
                      answer, and the symptom is otherwise just silence. --%>
                <.badge
                  :if={survey.status == :published and Map.get(@usage_counts, survey.id, 0) == 0}
                  tone="warning"
                >
                  {gettext("not in any course")}
                </.badge>
              </div>
            </div>

            <div class="flex shrink-0 items-center gap-1">
              <.button size="sm" navigate={~p"/studio/surveys/#{survey.id}/builder"}>
                <%!-- Reuses the count already loaded: a per-row
                      `survey_editable?/1` would be one query per row. --%>
                {if Map.get(@counts, survey.id, 0) == 0,
                  do: gettext("Edit"),
                  else: gettext("Open")}
              </.button>
              <.button
                :if={
                  Map.get(@counts, survey.id, 0) > 0 &&
                    Identity.can?(@current_user, "surveys.results.read")
                }
                size="sm"
                variant="primary"
                navigate={~p"/studio/surveys/#{survey.id}/results"}
                id={"results-#{survey.id}"}
              >
                {gettext("Results")}
              </.button>
              <button
                :if={survey.status == :archived && Identity.can?(@current_user, "surveys.update")}
                type="button"
                phx-click="restore"
                phx-value-id={survey.id}
                class="btn btn-ghost btn-sm btn-square text-base-content/50"
                aria-label={gettext("Restore")}
              >
                <.icon name="hero-arrow-uturn-left" class="size-4" />
              </button>
              <button
                :if={survey.status != :archived && Identity.can?(@current_user, "surveys.delete")}
                type="button"
                phx-click="archive_click"
                phx-value-id={survey.id}
                id={"archive-#{survey.id}"}
                class="btn btn-ghost btn-sm btn-square text-base-content/50 hover:text-error"
                aria-label={gettext("Archive")}
              >
                <.icon name="hero-archive-box" class="size-4" />
              </button>
            </div>
          </div>
        </div>

        <.pagination
          meta={@meta}
          path_fn={&build_path(@search, @show_archived?, &1)}
        />
      </.page_container>

      <.modal
        id="new-survey-modal"
        show={@live_action == :new}
        title={gettext("New survey")}
        on_cancel={JS.navigate(~p"/studio/surveys")}
      >
        <.form for={@form} id="survey-form" phx-change="validate" phx-submit="create">
          <.input field={@form[:title]} type="text" label={gettext("Title")} autofocus />
          <div class="modal-action">
            <.button variant="ghost" size="sm" navigate={~p"/studio/surveys"}>
              {gettext("Cancel")}
            </.button>
            <.button variant="primary" size="sm" type="submit" phx-disable-with={gettext("Creating…")}>
              {gettext("Create and open builder")}
            </.button>
          </div>
        </.form>
      </.modal>

      <.modal
        id="archive-survey-modal"
        show={@survey_to_archive != nil}
        title={gettext("Archive this survey?")}
        description={
          gettext("It disappears from the list but keeps every response. You can restore it later.")
        }
        on_cancel={JS.push("cancel_archive")}
        on_confirm={JS.push("confirm_archive")}
        confirm_label={gettext("Archive")}
      />
    </div>
    """
  end

  defp status_label(:draft), do: gettext("Draft")
  defp status_label(:published), do: gettext("Published")
  defp status_label(:closed), do: gettext("Closed")
  defp status_label(:archived), do: gettext("Archived")

  defp status_tone(:draft), do: "neutral"
  defp status_tone(:published), do: "success"
  defp status_tone(:closed), do: "warning"
  defp status_tone(:archived), do: "neutral"
end
