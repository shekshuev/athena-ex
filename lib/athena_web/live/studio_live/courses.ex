defmodule AthenaWeb.StudioLive.Courses do
  @moduledoc """
  LiveView for managing courses in the Studio.

  Displays a paginated and searchable list of courses using Streams for optimal
  DOM diffing. Handles course soft-deletion and integrates with `CourseFormComponent`
  for creating and editing courses via a slide-over.
  """
  use AthenaWeb, :live_view

  alias Athena.Content
  alias Athena.Content.Course
  alias Athena.Identity
  alias AthenaWeb.StudioLive.CourseFormComponent

  on_mount {AthenaWeb.Hooks.Permission, "courses.read"}

  @doc """
  Initializes the LiveView, setting up the courses stream and default assigns.
  """
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(course_to_delete: nil)
     |> stream(:courses, [])}
  end

  @doc """
  Handles URL parameters for pagination, search, and live actions (:index, :new, :edit).
  """
  @spec handle_params(map(), String.t(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  @impl true
  def handle_params(params, _url, socket) do
    search = Map.get(params, "search", "")

    flop_params =
      if search != "" do
        Map.put(params, "filters", %{
          "0" => %{"field" => "title", "op" => "ilike_and", "value" => search}
        })
      else
        params
      end

    case Content.list_courses(socket.assigns.current_user, flop_params) do
      {:ok, {courses, meta}} ->
        socket =
          socket
          |> assign(meta: meta, search: search)
          |> stream(:courses, courses, reset: true)
          |> apply_action(socket.assigns.live_action, params)

        {:noreply, socket}

      {:error, _meta} ->
        {:noreply, push_patch(socket, to: ~p"/studio/courses")}
    end
  end

  defp apply_action(socket, :index, _params) do
    assign(socket, page_title: gettext("Courses"), course: nil)
  end

  defp apply_action(socket, :new, _params) do
    if Identity.can?(socket.assigns.current_user, "courses.create") do
      assign(socket, page_title: gettext("Create Course"), course: %Course{})
    else
      socket
      |> put_flash(:error, gettext("You don't have permission to create courses."))
      |> push_patch(to: ~p"/studio/courses")
    end
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    if Identity.can?(socket.assigns.current_user, "courses.update") do
      case Content.get_course(socket.assigns.current_user, id) do
        {:ok, course} -> assign(socket, page_title: gettext("Edit Course"), course: course)
        _ -> push_patch(socket, to: ~p"/studio/courses")
      end
    else
      socket
      |> put_flash(:error, gettext("You don't have permission to edit courses."))
      |> push_patch(to: ~p"/studio/courses")
    end
  end

  @doc """
  Handles UI events such as searching and course deletion confirmations.
  """
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  @impl true
  def handle_event("search", %{"search" => search}, socket) do
    params = %{
      "search" => search,
      "page" => 1,
      "page_size" => socket.assigns.meta.page_size
    }

    {:noreply, push_patch(socket, to: ~p"/studio/courses?#{params}")}
  end

  def handle_event("delete_click", %{"id" => id}, socket) do
    if Identity.can?(socket.assigns.current_user, "courses.delete") do
      {:ok, course} = Content.get_course(socket.assigns.current_user, id)
      {:noreply, assign(socket, course_to_delete: course)}
    else
      {:noreply,
       socket
       |> put_flash(:error, gettext("You don't have permission to delete courses."))
       |> push_patch(to: ~p"/studio/courses")}
    end
  end

  def handle_event("confirm_delete", _, %{assigns: %{course_to_delete: course}} = socket) do
    case Content.soft_delete_course(socket.assigns.current_user, course) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Course deleted successfully"))
         |> stream_delete(:courses, course)
         |> assign(course_to_delete: nil)}

      {:error, _} ->
        {:noreply, socket |> put_flash(:error, gettext("Failed to delete course"))}
    end
  end

  def handle_event("cancel_delete", _, socket) do
    {:noreply, assign(socket, course_to_delete: nil)}
  end

  @doc """
  Handles messages from child components, such as a successfully saved course.
  """
  @spec handle_info(term(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  @impl true
  def handle_info({CourseFormComponent, {:saved, course}}, socket) do
    {:noreply, stream_insert(socket, :courses, course)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex justify-between items-center">
        <div>
          <h1 class="text-2xl font-display font-bold text-base-content">{gettext("Courses")}</h1>
          <p class="text-base-content/60">
            {gettext("Manage your educational content and materials.")}
          </p>
        </div>
        <.button
          :if={Identity.can?(@current_user, "courses.create")}
          patch={~p"/studio/courses/new"}
          class="btn btn-primary"
        >
          <.icon name="hero-plus" class="size-5" />
          {gettext("Create Course")}
        </.button>
      </div>

      <div class="flex gap-4">
        <.form for={nil} phx-change="search" phx-submit="search" class="w-full max-w-sm">
          <div class="relative">
            <.icon
              name="hero-magnifying-glass"
              class="absolute left-3 top-3.5 size-5 text-base-content/50 z-10"
            />
            <.input
              type="text"
              name="search"
              value={@search}
              placeholder={gettext("Search courses...")}
              class="input input-bordered w-full pl-10"
              phx-debounce="500"
            />
          </div>
        </.form>
      </div>

      <.table id="courses" rows={@streams.courses}>
        <:col :let={{_id, course}} label={gettext("Title")}>
          <span class="font-bold">{course.title}</span>
        </:col>
        <:col :let={{_id, course}} label={gettext("Status")}>
          <.status_badge status={course.status} />
        </:col>
        <:col :let={{_id, course}} label={gettext("Created At")}>
          <span class="text-sm opacity-60">{Calendar.strftime(course.inserted_at, "%d.%m.%Y")}</span>
        </:col>
        <:action :let={{_id, course}}>
          <div class="flex justify-end gap-2">
            <.button
              :if={Identity.can?(@current_user, "courses.update")}
              navigate={~p"/studio/courses/#{course.id}/builder"}
              class="btn btn-primary btn-xs btn-square btn-soft"
              title={gettext("Open Builder")}
            >
              <.icon name="hero-wrench-screwdriver" class="size-4" />
            </.button>

            <.button
              :if={Identity.can?(@current_user, "courses.update")}
              patch={~p"/studio/courses/#{course.id}/edit"}
              class="btn btn-ghost btn-xs btn-square"
              title={gettext("Edit Settings")}
            >
              <.icon name="hero-pencil-square" class="size-4" />
            </.button>

            <.button
              :if={Identity.can?(@current_user, "courses.delete")}
              type="button"
              phx-click="delete_click"
              phx-value-id={course.id}
              class="btn btn-ghost btn-xs btn-square text-error hover:bg-error/10"
              title={gettext("Delete")}
            >
              <.icon name="hero-trash" class="size-4" />
            </.button>
          </div>
        </:action>
      </.table>

      <div class="flex justify-end">
        <.pagination
          meta={@meta}
          path_fn={fn p -> ~p"/studio/courses?#{%{"page" => p, "search" => @search}}" end}
        />
      </div>

      <.slide_over
        id="course-slideover"
        show={@live_action in [:new, :edit]}
        title={@page_title}
        on_close={JS.patch(~p"/studio/courses")}
      >
        <.live_component
          :if={@course}
          module={CourseFormComponent}
          id={@course.id || :new}
          action={@live_action}
          course={@course}
          current_user={@current_user}
          patch={~p"/studio/courses"}
        />
      </.slide_over>

      <.modal
        id="delete-course-modal"
        show={@course_to_delete != nil}
        title={gettext("Delete Course")}
        description={
          gettext(
            "Are you sure you want to move this course to the archive? Users will no longer be able to access it."
          )
        }
        confirm_label={gettext("Delete")}
        danger={true}
        on_cancel={JS.push("cancel_delete")}
        on_confirm={JS.push("confirm_delete")}
      />
    </div>
    """
  end

  defp status_badge(assigns) do
    ~H"""
    <span class={[
      "badge badge-sm font-bold",
      @status == :published && "badge-success badge-soft",
      @status == :draft && "badge-warning badge-soft",
      @status == :archived && "badge-error badge-soft"
    ]}>
      {Atom.to_string(@status) |> String.capitalize()}
    </span>
    """
  end
end
