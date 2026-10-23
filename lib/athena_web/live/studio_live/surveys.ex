defmodule AthenaWeb.StudioLive.Surveys do
  @moduledoc """
  The survey list: every survey the current user may read, with its question
  and response counts, plus create and delete.

  Laid out as the same searchable, sortable, paginated `<.table>` every other
  list page in the app uses, with the filters carried in the query string so a
  patch (sorting, paging, opening the create modal) never loses them.

  Authoring lives in `AthenaWeb.StudioLive.SurveyBuilder` and results attach
  here (the list is where someone goes to ask "what did students say"), which
  is why both sit under `/studio` rather than splitting authoring from reading
  across two sections of the app.

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
     |> assign(page_title: gettext("Surveys"), survey_to_delete: nil)
     |> stream(:surveys, [])}
  end

  @impl true
  def handle_params(params, _url, socket) do
    search = Map.get(params, "search", "")
    flop_params = with_search(params, search)

    case Surveys.list_surveys_for_user(socket.assigns.current_user, flop_params) do
      {:ok, {surveys, meta}} ->
        {:noreply,
         socket
         |> assign(
           meta: meta,
           search: search,
           counts: response_counts(surveys),
           question_counts: question_counts(surveys),
           usage_counts: Content.survey_usage_counts(Enum.map(surveys, & &1.id)),
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
  def handle_event("update_filters", filters, socket) do
    search = Map.get(filters, "search", socket.assigns.search)
    params = build_query_params(socket.assigns, %{"search" => search, "page" => 1})
    {:noreply, push_patch(socket, to: ~p"/studio/surveys?#{params}")}
  end

  def handle_event("update_page_size", %{"page_size" => size}, socket) do
    params = build_query_params(socket.assigns, %{"page_size" => size, "page" => 1})
    {:noreply, push_patch(socket, to: ~p"/studio/surveys?#{params}")}
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

  def handle_event("delete_click", %{"id" => id}, socket) do
    case authorized(socket, id, "surveys.delete") do
      {:ok, survey} -> {:noreply, assign(socket, survey_to_delete: survey)}
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, survey_to_delete: nil)}
  end

  def handle_event("confirm_delete", _params, socket) do
    survey = socket.assigns.survey_to_delete

    with %Survey{} <- survey,
         {:ok, _deleted} <- Surveys.delete_survey(survey) do
      {:noreply,
       socket
       |> assign(survey_to_delete: nil)
       |> put_flash(:info, gettext("Survey deleted."))
       |> stream_delete(:surveys, survey)}
    else
      nil ->
        {:noreply, assign(socket, survey_to_delete: nil)}

      # The context refuses to destroy answers, which are usually the only
      # record of what students said - so say why rather than just failing.
      {:error, :has_responses} ->
        {:noreply,
         socket
         |> assign(survey_to_delete: nil)
         |> put_flash(
           :error,
           gettext("This survey already has responses, so it cannot be deleted.")
         )}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(survey_to_delete: nil)
         |> put_flash(:error, gettext("Could not delete that survey."))}
    end
  end

  # Permission *and* the record-level `own_only` policy: a role holding
  # `surveys.delete` with that policy must be refused on someone else's
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

  @doc false
  defp build_query_params(assigns, overrides) do
    meta = assigns.meta

    order_by =
      meta.flop.order_by
      |> List.wrap()
      |> Enum.map(&to_string/1)

    order_directions =
      meta.flop.order_directions
      |> List.wrap()
      |> Enum.map(&to_string/1)

    %{
      "search" => assigns.search,
      "page" => meta.current_page,
      "page_size" => meta.page_size,
      "order_by" => order_by,
      "order_directions" => order_directions
    }
    |> Map.merge(overrides)
    |> Enum.reject(fn {_, v} -> is_nil(v) or v == "" or v == [] end)
    |> Map.new()
  end

  # -- render ---------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <.page_container size="wide" class="space-y-6">
      <div class="flex justify-between items-center">
        <div>
          <h1 class="text-2xl font-display font-bold text-base-content">{gettext("Surveys")}</h1>
          <p class="text-base-content/60">
            {gettext("Collect feedback from students. Answers from a cohort stay grouped by cohort.")}
          </p>
        </div>
        <.button
          :if={Identity.can?(@current_user, "surveys.create")}
          id="new-survey"
          patch={~p"/studio/surveys/new?#{build_query_params(assigns, %{})}"}
          class="btn btn-primary"
        >
          <.icon name="hero-plus" class="size-5" />
          {gettext("New survey")}
        </.button>
      </div>

      <.form
        for={nil}
        phx-change="update_filters"
        phx-submit="update_filters"
        class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4"
      >
        <div class="relative">
          <.icon
            name="hero-magnifying-glass"
            class="absolute left-3 top-3.5 size-5 text-base-content/50 z-10"
          />
          <.input
            type="text"
            name="search"
            value={@search}
            placeholder={gettext("Search surveys...")}
            class="input input-bordered w-full pl-10"
            phx-debounce="500"
          />
        </div>
      </.form>

      <% path_fn = fn overrides -> ~p"/studio/surveys?#{build_query_params(assigns, overrides)}" end %>

      <.table id="surveys" rows={@streams.surveys} meta={@meta} path_fn={path_fn}>
        <:col :let={{_id, survey}} label={gettext("Title")} sort="title">
          <div class="flex flex-wrap items-center gap-2">
            <.link
              navigate={~p"/studio/surveys/#{survey.id}/builder"}
              class="font-bold text-primary"
            >
              {survey.title}
            </.link>
            <%!-- A published survey in no course is a survey nobody can
                  answer, and the symptom is otherwise just silence. --%>
            <.badge
              :if={survey.status == :published and Map.get(@usage_counts, survey.id, 0) == 0}
              tone="warning"
            >
              {gettext("not in any course")}
            </.badge>
          </div>
        </:col>
        <:col :let={{_id, survey}} label={gettext("Questions")}>
          <span class="text-sm opacity-60">{Map.get(@question_counts, survey.id, 0)}</span>
        </:col>
        <:col :let={{_id, survey}} label={gettext("Responses")}>
          <span class="text-sm opacity-60">{Map.get(@counts, survey.id, 0)}</span>
        </:col>
        <:col :let={{_id, survey}} label={gettext("Created")} sort="inserted_at">
          <span class="text-sm opacity-60">
            {TimeZones.format(survey.inserted_at, "%d.%m.%Y")}
          </span>
        </:col>
        <:action :let={{_id, survey}}>
          <div class="flex items-center gap-2 justify-end">
            <.button variant="ghost" size="xs" navigate={~p"/studio/surveys/#{survey.id}/builder"}>
              <%!-- Reuses the count already loaded: a per-row
                    `survey_editable?/1` would be one query per row. --%>
              {if Map.get(@counts, survey.id, 0) == 0,
                do: gettext("Edit"),
                else: gettext("Open")}
            </.button>
            <.button
              :if={Map.get(@counts, survey.id, 0) > 0}
              id={"results-#{survey.id}"}
              variant="ghost"
              size="xs"
              class="text-primary hover:bg-primary/10"
              navigate={~p"/studio/surveys/#{survey.id}/results"}
            >
              <.icon name="hero-chart-bar" class="size-4" />
              <span class="hidden sm:inline">{gettext("Results")}</span>
            </.button>
            <.icon_button
              :if={Identity.can?(@current_user, "surveys.delete")}
              id={"delete-#{survey.id}"}
              type="button"
              phx-click="delete_click"
              phx-value-id={survey.id}
              icon="hero-trash"
              label={gettext("Delete")}
              variant="danger"
            />
          </div>
        </:action>
      </.table>

      <.empty_state
        :if={@meta.total_count == 0}
        icon="hero-clipboard-document-list"
        title={gettext("No surveys yet")}
        description={gettext("Create a survey to ask students how a course is going.")}
      />

      <div class="flex justify-end">
        <.pagination meta={@meta} path_fn={path_fn} />
      </div>

      <.modal
        id="new-survey-modal"
        show={@live_action == :new}
        title={gettext("New survey")}
        on_cancel={JS.patch(~p"/studio/surveys?#{build_query_params(assigns, %{})}")}
      >
        <.form for={@form} id="survey-form" phx-change="validate" phx-submit="create">
          <.input field={@form[:title]} type="text" label={gettext("Title")} autofocus />
          <div class="modal-action">
            <.button
              variant="ghost"
              size="sm"
              patch={~p"/studio/surveys?#{build_query_params(assigns, %{})}"}
            >
              {gettext("Cancel")}
            </.button>
            <.button variant="primary" size="sm" type="submit" phx-disable-with={gettext("Creating…")}>
              {gettext("Create and open builder")}
            </.button>
          </div>
        </.form>
      </.modal>

      <.modal
        id="delete-survey-modal"
        show={@survey_to_delete != nil}
        title={gettext("Delete this survey?")}
        description={
          gettext(
            "It is removed along with its questions. A survey that already has responses cannot be deleted."
          )
        }
        confirm_label={gettext("Delete")}
        danger={true}
        on_cancel={JS.push("cancel_delete")}
        on_confirm={JS.push("confirm_delete")}
      />
    </.page_container>
    """
  end
end
