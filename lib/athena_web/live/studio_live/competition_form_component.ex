defmodule AthenaWeb.StudioLive.CompetitionFormComponent do
  @moduledoc """
  A LiveComponent for creating and editing competition course metadata.

  A `:type == :competition`-fixed sibling of `AthenaWeb.StudioLive.CourseFormComponent`
  - same `Athena.Content.Course` changeset and `Athena.Content` context calls,
  just without the type dropdown (a competition is always a competition here).
  """
  use AthenaWeb, :live_component

  alias Athena.Content
  alias Athena.Content.Course
  alias Athena.TimeZones

  @impl true
  def update(%{course: course} = assigns, socket) do
    changeset = Course.changeset(%{course | type: :competition}, %{})

    status_options = [
      {gettext("Draft"), :draft},
      {gettext("Published"), :published},
      {gettext("Archived"), :archived}
    ]

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:form, to_form(changeset))
     |> assign(:status_options, status_options)}
  end

  @impl true
  def handle_event("validate", %{"course" => course_params}, socket) do
    changeset =
      socket.assigns.course
      |> Course.changeset(schedule_params(course_params))
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("save", %{"course" => course_params}, socket) do
    course_params = schedule_params(course_params)

    course_params =
      if socket.assigns.action == :new do
        Map.put(course_params, "owner_id", socket.assigns.current_user.id)
      else
        course_params
      end

    save_course(socket, socket.assigns.action, course_params)
  end

  defp save_course(socket, :edit, course_params) do
    case Content.update_course(socket.assigns.current_user, socket.assigns.course, course_params) do
      {:ok, course} ->
        notify_parent({:saved, course})

        {:noreply,
         socket
         |> put_flash(:info, gettext("Competition updated successfully"))
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp save_course(socket, :new, course_params) do
    case Content.create_course(socket.assigns.current_user, course_params) do
      {:ok, course} ->
        notify_parent({:saved, course})

        {:noreply,
         socket
         |> put_flash(:info, gettext("Competition created successfully"))
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  # Pins the type and turns the two wall-clock `datetime-local` values into
  # UTC before they reach the changeset.
  defp schedule_params(course_params) do
    course_params
    |> Map.put("type", "competition")
    |> TimeZones.localize_params(~w(starts_at ends_at))
  end

  defp notify_parent(msg), do: send(self(), {__MODULE__, msg})

  @impl true
  def render(assigns) do
    ~H"""
    <div class="h-full flex flex-col">
      <.form
        for={@form}
        id="competition-form"
        phx-target={@myself}
        phx-change="validate"
        phx-submit="save"
        class="flex flex-col h-full"
      >
        <div class="flex-1 overflow-y-auto p-6 space-y-6">
          <div class="divider text-xs font-bold uppercase text-base-content/50">
            {gettext("Competition Settings")}
          </div>

          <.input
            field={@form[:title]}
            type="text"
            label={gettext("Title")}
            placeholder={gettext("e.g. Regional Programming Competition 2026")}
            required
            phx-debounce="500"
          />

          <.input
            field={@form[:code]}
            type="text"
            label={gettext("Competition Code")}
            placeholder={gettext("e.g. OLYMP-2026")}
            required={false}
            phx-debounce="500"
          />

          <.input
            field={@form[:description]}
            type="textarea"
            label={gettext("Description")}
            placeholder={gettext("Briefly describe the competition...")}
            rows="4"
            phx-debounce="500"
          />

          <.input
            field={@form[:status]}
            type="select"
            label={gettext("Visibility Status")}
            options={@status_options}
            required
          />

          <div class="divider text-xs font-bold uppercase text-base-content/50">
            {gettext("Competition Schedule")}
          </div>

          <p class="text-xs text-base-content/60 -mt-2">
            {gettext(
              "Optional. The dashboard only shows a competition from a month before it starts until a month after it ends. Leave empty to always show it."
            )}
          </p>

          <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
            <.input
              field={@form[:starts_at]}
              type="datetime-local"
              label={gettext("Starts At")}
            />
            <.input field={@form[:ends_at]} type="datetime-local" label={gettext("Ends At")} />
          </div>
        </div>

        <div class="shrink-0 p-6 border-t border-base-200 bg-base-100 flex justify-end gap-3">
          <.button variant="ghost" patch={@patch}>{gettext("Cancel")}</.button>
          <.button type="submit" variant="primary" phx-disable-with={gettext("Saving...")}>
            {gettext("Save")}
          </.button>
        </div>
      </.form>
    </div>
    """
  end
end
