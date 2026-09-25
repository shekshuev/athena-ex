defmodule AthenaWeb.TeachingLive.Sprints do
  @moduledoc """
  Instructor-facing sprint management: pick a cohort you manage, a period,
  and an XP multiplier (x1.5/x2/x3 — a fixed pick-list, not free-form
  input, so there's less room to accidentally wreck a course's XP
  economy). A sprint boosts XP already flowing through the existing
  weekly league and badges — there's no separate sprint leaderboard to
  build or maintain.
  """
  use AthenaWeb, :live_view

  alias Athena.{Learning, Gamification}
  alias Athena.Gamification.Sprint

  on_mount {AthenaWeb.Hooks.Permission, "cohorts.read"}

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    {:ok,
     socket
     |> assign(:cohort_options, Learning.get_cohort_options(user))
     |> assign(:selected_cohort_id, nil)
     |> assign(:sprints, [])
     |> assign(:sprint_to_delete, nil)
     |> assign(:form, to_form(Sprint.changeset(%Sprint{}, %{})))}
  end

  @impl true
  def handle_event("select_cohort", %{"cohort_id" => cohort_id}, socket) do
    sprints =
      if cohort_id == "", do: [], else: Gamification.list_sprints_for_cohort(cohort_id)

    {:noreply,
     socket
     |> assign(:selected_cohort_id, cohort_id)
     |> assign(:sprints, sprints)
     |> assign(:form, to_form(Sprint.changeset(%Sprint{}, %{"cohort_id" => cohort_id})))}
  end

  def handle_event("validate", %{"sprint" => params}, socket) do
    params = TimeZones.localize_params(params, ~w(starts_at ends_at))
    changeset = %Sprint{} |> Sprint.changeset(params) |> Map.put(:action, :validate)
    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("save", %{"sprint" => params}, socket) do
    params = TimeZones.localize_params(params, ~w(starts_at ends_at))
    user = socket.assigns.current_user

    case Gamification.create_sprint(user, params) do
      {:ok, sprint} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Sprint created."))
         |> assign(:sprints, [sprint | socket.assigns.sprints])
         |> assign(
           :form,
           to_form(
             Sprint.changeset(%Sprint{}, %{"cohort_id" => socket.assigns.selected_cohort_id})
           )
         )}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, gettext("You don't manage this cohort."))}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  def handle_event("delete_click", %{"id" => id}, socket) do
    sprint = Enum.find(socket.assigns.sprints, &(&1.id == id))
    {:noreply, assign(socket, :sprint_to_delete, sprint)}
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, :sprint_to_delete, nil)}
  end

  def handle_event("confirm_delete", _params, %{assigns: %{sprint_to_delete: sprint}} = socket) do
    user = socket.assigns.current_user

    case Gamification.delete_sprint(user, sprint) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:sprints, Enum.reject(socket.assigns.sprints, &(&1.id == sprint.id)))
         |> assign(:sprint_to_delete, nil)}

      _ ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Could not delete this sprint."))
         |> assign(:sprint_to_delete, nil)}
    end
  end

  defp active?(sprint) do
    now = DateTime.utc_now()

    sprint.is_active and DateTime.compare(sprint.starts_at, now) != :gt and
      DateTime.compare(sprint.ends_at, now) != :lt
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.page_container size="narrow" class="space-y-6">
      <div>
        <h1 class="text-3xl font-display font-black uppercase tracking-tight">
          {gettext("Sprints")}
        </h1>
        <p class="text-base-content/60 text-sm mt-1">
          {gettext("Temporarily boost XP for a cohort — useful right before an exam or deadline.")}
        </p>
      </div>

      <form phx-change="select_cohort" class="max-w-sm">
        <select name="cohort_id" class="select select-bordered w-full">
          <option value="">{gettext("Select a cohort...")}</option>
          <option :for={{name, id} <- @cohort_options} value={id}>{name}</option>
        </select>
      </form>

      <div :if={@selected_cohort_id && @selected_cohort_id != ""} class="space-y-6">
        <div class="card bg-base-100 border border-base-300 rounded-sm">
          <div class="card-body">
            <h2 class="font-display font-black uppercase text-sm text-base-content/70 mb-4">
              {gettext("New Sprint")}
            </h2>

            <.form
              for={@form}
              id="sprint-form"
              phx-change="validate"
              phx-submit="save"
              class="space-y-4"
            >
              <input type="hidden" name="sprint[cohort_id]" value={@selected_cohort_id} />

              <.input field={@form[:title]} type="text" label={gettext("Title")} required />

              <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
                <.input
                  field={@form[:starts_at]}
                  type="datetime-local"
                  label={gettext("Starts")}
                  required
                />
                <.input
                  field={@form[:ends_at]}
                  type="datetime-local"
                  label={gettext("Ends")}
                  required
                />
              </div>

              <.input
                field={@form[:xp_multiplier]}
                type="select"
                label={gettext("XP Multiplier")}
                options={[{"x1.5", "1.5"}, {"x2", "2"}, {"x3", "3"}]}
              />

              <div class="flex justify-end">
                <.button type="submit" variant="primary" phx-disable-with={gettext("Saving...")}>
                  {gettext("Create Sprint")}
                </.button>
              </div>
            </.form>
          </div>
        </div>

        <div>
          <h2 class="font-display font-black uppercase text-sm text-base-content/70 mb-3">
            {gettext("Existing Sprints")}
          </h2>

          <div :if={@sprints == []} class="text-base-content/50 text-sm">
            {gettext("No sprints for this cohort yet.")}
          </div>

          <ul class="space-y-2">
            <li
              :for={sprint <- @sprints}
              id={"sprint-#{sprint.id}"}
              class="flex items-center justify-between p-4 bg-base-100 border border-base-300 rounded-sm"
            >
              <div>
                <div class="font-bold flex items-center gap-2">
                  {sprint.title}
                  <span :if={active?(sprint)} class="badge badge-success badge-sm">
                    {gettext("Active now")}
                  </span>
                </div>
                <div class="text-xs text-base-content/50">
                  {TimeZones.format(sprint.starts_at, "%d.%m %H:%M")} — {TimeZones.format(
                    sprint.ends_at,
                    "%d.%m %H:%M"
                  )} · x{sprint.xp_multiplier}
                </div>
              </div>
              <.icon_button
                type="button"
                phx-click="delete_click"
                phx-value-id={sprint.id}
                icon="hero-trash"
                label={gettext("Delete")}
                variant="danger"
              />
            </li>
          </ul>
        </div>
      </div>

      <.modal
        id="delete-sprint-modal"
        show={@sprint_to_delete != nil}
        title={gettext("Delete this sprint?")}
        on_cancel={JS.push("cancel_delete")}
        on_confirm={JS.push("confirm_delete")}
        confirm_label={gettext("Delete")}
        danger={true}
      />
    </.page_container>
    """
  end
end
