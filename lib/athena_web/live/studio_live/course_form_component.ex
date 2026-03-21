defmodule AthenaWeb.StudioLive.CourseFormComponent do
  @moduledoc """
  A LiveComponent for creating and editing course metadata.

  Handles the form state for the `Athena.Content.Course` schema. 
  It automatically assigns the current user as the owner when creating 
  a new course and delegates database operations to the `Athena.Content` context.
  """
  use AthenaWeb, :live_component

  alias Athena.Content
  alias Athena.Content.Course

  @doc """
  Initializes the component state.

  Builds the initial `Ecto.Changeset` from an existing course or an empty struct,
  and fetches available status options for the select dropdown.
  """
  @spec update(map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  @impl true
  def update(%{course: course} = assigns, socket) do
    changeset = Course.changeset(course, %{})

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

  @doc """
  Handles UI validation events.
  """
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  @impl true
  def handle_event("validate", %{"course" => course_params}, socket) do
    changeset =
      socket.assigns.course
      |> Course.changeset(course_params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("save", %{"course" => course_params}, socket) do
    # Inject the owner_id from the current session if creating a new course
    course_params =
      if socket.assigns.action == :new do
        Map.put(course_params, "owner_id", socket.assigns.current_user.id)
      else
        course_params
      end

    save_course(socket, socket.assigns.action, course_params)
  end

  defp save_course(socket, :edit, course_params) do
    case Content.update_course(socket.assigns.course, course_params) do
      {:ok, course} ->
        notify_parent({:saved, course})

        {:noreply,
         socket
         |> put_flash(:info, gettext("Course updated successfully"))
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp save_course(socket, :new, course_params) do
    case Content.create_course(course_params) do
      {:ok, course} ->
        notify_parent({:saved, course})

        {:noreply,
         socket
         |> put_flash(:info, gettext("Course created successfully"))
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp notify_parent(msg), do: send(self(), {__MODULE__, msg})

  @impl true
  def render(assigns) do
    ~H"""
    <div class="h-full flex flex-col">
      <.form
        for={@form}
        id="course-form"
        phx-target={@myself}
        phx-change="validate"
        phx-submit="save"
        class="flex flex-col h-full"
      >
        <div class="flex-1 overflow-y-auto p-6 space-y-6">
          <div class="divider text-xs font-bold uppercase text-base-content/50">
            {gettext("Course Settings")}
          </div>

          <.input
            field={@form[:title]}
            type="text"
            label={gettext("Title")}
            placeholder={gettext("e.g. Advanced Elixir Mastery")}
            required
          />

          <.input
            field={@form[:description]}
            type="textarea"
            label={gettext("Description")}
            placeholder={gettext("Briefly describe what students will learn...")}
            rows="4"
          />

          <.input
            field={@form[:status]}
            type="select"
            label={gettext("Visibility Status")}
            options={@status_options}
            required
          />
        </div>

        <div class="shrink-0 p-6 border-t border-base-200 bg-base-100 flex justify-end gap-3">
          <.link patch={@patch} class="btn btn-ghost">{gettext("Cancel")}</.link>
          <button type="submit" class="btn btn-primary" phx-disable-with={gettext("Saving...")}>
            {gettext("Save")}
          </button>
        </div>
      </.form>
    </div>
    """
  end
end
