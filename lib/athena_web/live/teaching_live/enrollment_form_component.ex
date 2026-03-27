defmodule AthenaWeb.TeachingLive.EnrollmentFormComponent do
  @moduledoc """
  A LiveComponent for assigning a course to a cohort.

  Features a real-time autocomplete search for active courses.
  Delegates database operations to the `Athena.Learning` context 
  and course searching to the `Athena.Content` context.
  """
  use AthenaWeb, :live_component

  alias Athena.Content
  alias Athena.Learning

  @doc """
  Initializes the component state with empty search results and selection.
  """
  @spec update(map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign(:search_query, "")
     |> assign(:search_results, [])
     |> assign(:selected_course, nil)
     |> assign(:error_msg, nil)}
  end

  @doc """
  Handles UI events: searching courses, selecting/clearing the course,
  and submitting the enrollment form.
  """
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  @impl true
  def handle_event("search_courses", %{"value" => query}, socket) do
    if String.length(query) >= 2 do
      courses = Content.search_courses_by_title(query)
      {:noreply, assign(socket, search_query: query, search_results: courses)}
    else
      {:noreply, assign(socket, search_query: query, search_results: [])}
    end
  end

  def handle_event("select_course", %{"id" => id, "title" => title}, socket) do
    {:noreply,
     socket
     |> assign(:selected_course, %{id: id, title: title})
     |> assign(:search_results, [])
     |> assign(:search_query, "")
     |> assign(:error_msg, nil)}
  end

  def handle_event("clear_course", _, socket) do
    {:noreply, assign(socket, selected_course: nil, error_msg: nil)}
  end

  def handle_event("save", _, %{assigns: %{selected_course: nil}} = socket) do
    {:noreply, assign(socket, error_msg: gettext("Please select a course."))}
  end

  def handle_event("save", _, socket) do
    %{cohort_id: cohort_id, selected_course: %{id: course_id}, patch: patch} = socket.assigns

    case Learning.enroll_cohort(cohort_id, course_id) do
      {:ok, enrollment} ->
        send(self(), {__MODULE__, {:saved, enrollment}})

        {:noreply,
         socket
         |> put_flash(:info, gettext("Course successfully assigned to the cohort."))
         |> push_patch(to: patch)}

      {:error, changeset} ->
        {:noreply, assign(socket, error_msg: parse_error_msg(changeset))}
    end
  end

  @doc false
  defp parse_error_msg(changeset) do
    if changeset.errors[:cohort_id] || changeset.errors[:course_id] do
      gettext("This course is already assigned to this cohort.")
    else
      gettext("Failed to assign course.")
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <form id="enrollment-form" phx-submit="save" phx-target={@myself} class="flex flex-col gap-6">
        <div class="form-control w-full relative">
          <label class="label">
            <span class="label-text font-bold">{gettext("Search Course by Title")}</span>
          </label>

          <%= if @selected_course do %>
            <div class="flex items-center justify-between p-3 border border-success/30 bg-success/10 text-success-content rounded-lg">
              <div class="flex items-center gap-2">
                <.icon name="hero-book-open" class="size-5" />
                <span class="font-bold">{@selected_course.title}</span>
              </div>

              <.button
                type="button"
                phx-click="clear_course"
                phx-target={@myself}
                class="btn btn-ghost btn-xs btn-square text-error hover:bg-error/20"
              >
                <.icon name="hero-x-mark" class="size-4" />
              </.button>
            </div>
          <% else %>
            <div class="relative">
              <input
                type="text"
                value={@search_query}
                phx-keyup="search_courses"
                phx-target={@myself}
                class={["input input-bordered w-full", @error_msg && "input-error"]}
                placeholder={gettext("Type at least 2 characters...")}
                autocomplete="off"
                phx-debounce="300"
                autofocus
              />
              <.icon
                name="hero-magnifying-glass"
                class="absolute right-3 top-3.5 size-5 text-base-content/40"
              />
            </div>

            <ul
              :if={@search_results != []}
              class="absolute top-18 left-0 w-full bg-base-100 shadow-2xl border border-base-200 rounded-lg z-50 max-h-60 overflow-y-auto"
            >
              <%= for course <- @search_results do %>
                <li
                  phx-click="select_course"
                  phx-target={@myself}
                  phx-value-id={course.id}
                  phx-value-title={course.title}
                  class="p-3 hover:bg-primary/10 hover:text-primary cursor-pointer border-b border-base-100 last:border-0 font-medium transition-colors"
                >
                  {course.title}
                </li>
              <% end %>
            </ul>
          <% end %>

          <p :if={@error_msg} class="mt-2 text-sm text-error font-bold flex items-center gap-1">
            <.icon name="hero-exclamation-circle" class="size-4" />
            {@error_msg}
          </p>
        </div>

        <div class="flex justify-end gap-3 mt-4">
          <.button
            type="button"
            class="btn btn-ghost"
            phx-click={JS.patch(@patch)}
          >
            {gettext("Cancel")}
          </.button>
          <.button type="submit" class="btn btn-primary" disabled={is_nil(@selected_course)}>
            {gettext("Assign Course")}
          </.button>
        </div>
      </form>
    </div>
    """
  end
end
