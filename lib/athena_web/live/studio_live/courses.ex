defmodule AthenaWeb.StudioLive.Courses do
  @moduledoc """
  LiveView for managing courses in the Studio.
  """
  use AthenaWeb, :live_view

  alias Athena.Content
  alias Athena.Content.Course
  alias Athena.Identity
  alias AthenaWeb.StudioLive.{CourseFormComponent, CourseShareComponent}

  on_mount {AthenaWeb.Hooks.Permission, "courses.read"}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Athena.PubSub, "user_courses:#{socket.assigns.current_user.id}")
      Phoenix.PubSub.subscribe(Athena.PubSub, "public_courses")
    end

    {:ok,
     socket
     |> assign(course_to_delete: nil)
     |> assign(course_to_share: nil)
     |> stream(:courses, [])}
  end

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
    case Content.get_course(socket.assigns.current_user, id) do
      {:ok, course} ->
        info = course_badges(course, socket.assigns.current_user)

        if info.role in [:owner, :writer] or
             Identity.can?(socket.assigns.current_user, "courses.update", course) do
          assign(socket, page_title: gettext("Edit Course"), course: course)
        else
          socket
          |> put_flash(:error, gettext("You don't have permission to edit this course."))
          |> push_patch(to: ~p"/studio/courses")
        end

      _ ->
        push_patch(socket, to: ~p"/studio/courses")
    end
  end

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
    {:ok, course} = Content.get_course(socket.assigns.current_user, id)

    if course.owner_id == socket.assigns.current_user.id or
         Identity.can?(socket.assigns.current_user, "courses.delete", course) do
      {:noreply, assign(socket, course_to_delete: course)}
    else
      {:noreply,
       socket
       |> put_flash(:error, gettext("Only the owner can delete this course."))
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

  def handle_event("share_click", %{"id" => id}, socket) do
    case Content.get_course(socket.assigns.current_user, id) do
      {:ok, course} ->
        if course.owner_id == socket.assigns.current_user.id or
             Identity.can?(socket.assigns.current_user, "courses.update", course) do
          {:noreply, assign(socket, course_to_share: course)}
        else
          {:noreply,
           socket |> put_flash(:error, gettext("Only the owner can share this course."))}
        end

      _ ->
        {:noreply, socket |> put_flash(:error, gettext("Cannot access this course."))}
    end
  end

  def handle_event("cancel_share", _, socket) do
    {:noreply, assign(socket, course_to_share: nil)}
  end

  @impl true
  def handle_info({CourseFormComponent, {:saved, course}}, socket) do
    {:noreply, stream_insert(socket, :courses, course)}
  end

  def handle_info({CourseShareComponent, {:updated, course}}, socket) do
    socket =
      if socket.assigns.course_to_share && socket.assigns.course_to_share.id == course.id do
        assign(socket, course_to_share: course)
      else
        socket
      end

    {:noreply, stream_insert(socket, :courses, course)}
  end

  @impl true
  def handle_info(:refresh_courses, socket) do
    params = %{
      "search" => socket.assigns.search,
      "page" => socket.assigns.meta.current_page,
      "page_size" => socket.assigns.meta.page_size
    }

    flop_params =
      if params["search"] != "" do
        Map.put(params, "filters", %{
          "0" => %{"field" => "title", "op" => "ilike_and", "value" => params["search"]}
        })
      else
        params
      end

    case Content.list_courses(socket.assigns.current_user, flop_params) do
      {:ok, {courses, meta}} ->
        {:noreply,
         socket
         |> assign(meta: meta)
         |> stream(:courses, courses, reset: true)}

      {:error, _meta} ->
        {:noreply, socket}
    end
  end

  defp course_badges(course, user) do
    shares = Content.list_course_shares(course)

    role =
      cond do
        course.owner_id == user.id -> :owner
        share = Enum.find(shares, &(&1.account_id == user.id)) -> share.role
        true -> :none
      end

    %{
      role: role,
      is_public: course.is_public,
      shares_count: length(shares)
    }
  end

  defp access_badges(assigns) do
    ~H"""
    <div class="flex gap-1 items-center">
      <span
        :if={@info.role != :none}
        class={[
          "badge badge-xs font-bold uppercase shrink-0",
          @info.role == :owner && "badge-primary badge-soft",
          @info.role == :writer && "badge-secondary badge-soft",
          @info.role == :reader && "badge-accent badge-soft"
        ]}
      >
        {Atom.to_string(@info.role)}
      </span>

      <span
        :if={@info.is_public}
        class="badge badge-xs badge-neutral font-bold uppercase shrink-0"
      >
        <.icon name="hero-globe-alt" class="size-3 mr-1" />
        {gettext("Public")}
      </span>

      <span
        :if={!@info.is_public and @info.shares_count > 0 and @info.role == :owner}
        class="badge badge-xs badge-info badge-soft font-bold shrink-0"
      >
        <.icon name="hero-users" class="size-3 mr-1" />
        {@info.shares_count}
      </span>
    </div>
    """
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
          <div class="flex flex-col gap-1 items-start">
            <span class="font-bold">{course.title}</span>
            <.access_badges info={course_badges(course, @current_user)} />
          </div>
        </:col>
        <:col :let={{_id, course}} label={gettext("Status")}>
          <.status_badge status={course.status} />
        </:col>
        <:col :let={{_id, course}} label={gettext("Created At")}>
          <span class="text-sm opacity-60">{Calendar.strftime(course.inserted_at, "%d.%m.%Y")}</span>
        </:col>
        <:action :let={{_id, course}}>
          <% info = course_badges(course, @current_user) %>
          <% can_edit =
            info.role in [:owner, :writer] or Identity.can?(@current_user, "courses.update", course) %>
          <% can_view = can_edit or info.role == :reader or info.is_public %>

          <div class="flex justify-end gap-2">
            <.button
              :if={can_view}
              navigate={~p"/studio/courses/#{course.id}/builder"}
              class="btn btn-primary btn-xs btn-square btn-soft"
              title={if can_edit, do: gettext("Open Builder"), else: gettext("View Course")}
            >
              <.icon
                name={if can_edit, do: "hero-wrench-screwdriver", else: "hero-eye"}
                class="size-4"
              />
            </.button>

            <.button
              :if={can_edit}
              patch={~p"/studio/courses/#{course.id}/edit"}
              class="btn btn-ghost btn-xs btn-square"
              title={gettext("Edit Settings")}
            >
              <.icon name="hero-pencil-square" class="size-4" />
            </.button>

            <.button
              :if={can_edit}
              type="button"
              phx-click="share_click"
              phx-value-id={course.id}
              class="btn btn-ghost btn-xs btn-square"
              title={gettext("Share Access")}
            >
              <.icon name="hero-share" class="size-4" />
            </.button>

            <.button
              :if={can_edit}
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
        description={gettext("Are you sure you want to move this course to the archive?")}
        confirm_label={gettext("Delete")}
        danger={true}
        on_cancel={JS.push("cancel_delete")}
        on_confirm={JS.push("confirm_delete")}
      />

      <.modal
        id="share-course-modal"
        show={@course_to_share != nil}
        title={
          gettext("Share Course: %{title}",
            title: if(@course_to_share, do: @course_to_share.title, else: "")
          )
        }
        on_cancel={JS.push("cancel_share")}
      >
        <.live_component
          :if={@course_to_share}
          module={CourseShareComponent}
          id={"share-#{@course_to_share.id}"}
          course={@course_to_share}
          current_user={@current_user}
        />
      </.modal>
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
