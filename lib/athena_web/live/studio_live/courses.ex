defmodule AthenaWeb.StudioLive.Courses do
  @moduledoc """
  LiveView for managing courses in the Studio.
  """
  use AthenaWeb, :live_view

  alias Athena.Content
  alias Athena.Content.Course
  alias Athena.Identity

  alias AthenaWeb.StudioLive.{
    CourseFormComponent,
    CourseShareComponent,
    CourseEnrollmentComponent
  }

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
     |> assign(course_to_enroll: nil)
     |> assign(course_to_duplicate: nil)
     |> assign(duplicate_title: "")
     |> assign(duplicate_error: nil)
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
        courses_with_owners = enrich_with_owners(courses)

        socket =
          socket
          |> assign(meta: meta, search: search)
          |> stream(:courses, courses_with_owners, reset: true)
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
    params = build_query_params(socket.assigns, %{"search" => search, "page" => 1})
    {:noreply, push_patch(socket, to: ~p"/studio/courses?#{params}")}
  end

  def handle_event("update_page_size", %{"page_size" => size}, socket) do
    params = build_query_params(socket.assigns, %{"page_size" => size, "page" => 1})
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

  def handle_event("enroll_click", %{"id" => id}, socket) do
    case Content.get_course(socket.assigns.current_user, id) do
      {:ok, course} ->
        if course.owner_id == socket.assigns.current_user.id or
             Identity.can?(socket.assigns.current_user, "courses.update", course) do
          {:noreply, assign(socket, course_to_enroll: course)}
        else
          {:noreply,
           socket |> put_flash(:error, gettext("You do not have permission to enroll students."))}
        end

      _ ->
        {:noreply, socket |> put_flash(:error, gettext("Cannot access this course."))}
    end
  end

  def handle_event("cancel_enroll", _, socket) do
    {:noreply, assign(socket, course_to_enroll: nil)}
  end

  def handle_event("duplicate_click", %{"id" => id}, socket) do
    case Content.get_course(socket.assigns.current_user, id) do
      {:ok, course} ->
        if course.owner_id == socket.assigns.current_user.id or
             Identity.can?(socket.assigns.current_user, "courses.update", course) do
          {:noreply,
           socket
           |> assign(course_to_duplicate: course)
           |> assign(duplicate_title: gettext("%{title} (Copy)", title: course.title))
           |> assign(duplicate_error: nil)}
        else
          {:noreply,
           socket
           |> put_flash(:error, gettext("You do not have permission to duplicate this course."))}
        end

      _ ->
        {:noreply, socket |> put_flash(:error, gettext("Cannot access this course."))}
    end
  end

  def handle_event("cancel_duplicate", _, socket) do
    {:noreply, assign(socket, course_to_duplicate: nil, duplicate_error: nil)}
  end

  def handle_event(
        "confirm_duplicate",
        %{"title" => title},
        %{assigns: %{course_to_duplicate: course}} = socket
      ) do
    case Content.duplicate_course(socket.assigns.current_user, course.id, title) do
      {:ok, new_course} ->
        [enriched_course] = enrich_with_owners([new_course])

        {:noreply,
         socket
         |> stream_insert(:courses, enriched_course, at: 0)
         |> put_flash(:info, gettext("Duplicating course in the background…"))
         |> assign(course_to_duplicate: nil, duplicate_error: nil)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, duplicate_error: changeset_error_message(changeset))}

      {:error, _reason} ->
        {:noreply, assign(socket, duplicate_error: gettext("Failed to duplicate course."))}
    end
  end

  def handle_event("retry_duplicate_click", %{"id" => id}, socket) do
    case Content.get_course(socket.assigns.current_user, id) do
      {:ok, course} ->
        case Content.retry_course_copy(socket.assigns.current_user, course) do
          {:ok, updated_course} ->
            [enriched_course] = enrich_with_owners([updated_course])

            {:noreply,
             socket
             |> stream_insert(:courses, enriched_course)
             |> put_flash(:info, gettext("Retrying course copy…"))}

          {:error, _reason} ->
            {:noreply, socket |> put_flash(:error, gettext("Failed to retry the copy."))}
        end

      _ ->
        {:noreply, socket |> put_flash(:error, gettext("Cannot access this course."))}
    end
  end

  @impl true
  def handle_info({CourseFormComponent, {:saved, course}}, socket) do
    [enriched_course] = enrich_with_owners([course])

    {:noreply, stream_insert(socket, :courses, enriched_course)}
  end

  def handle_info({CourseShareComponent, {:updated, course}}, socket) do
    socket =
      if socket.assigns.course_to_share && socket.assigns.course_to_share.id == course.id do
        assign(socket, course_to_share: course)
      else
        socket
      end

    [enriched_course] = enrich_with_owners([course])

    {:noreply, stream_insert(socket, :courses, enriched_course)}
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
        courses_with_owners = enrich_with_owners(courses)

        {:noreply,
         socket
         |> assign(meta: meta)
         |> stream(:courses, courses_with_owners, reset: true)}

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

  defp enrich_with_owners(courses) do
    owner_ids = courses |> Enum.map(& &1.owner_id) |> Enum.uniq()

    accounts_map = Identity.get_accounts_map(owner_ids)

    Enum.map(courses, fn course ->
      login = get_in(accounts_map, [course.owner_id, Access.key(:login)]) || "Unknown"
      Map.put(course, :owner_login, login)
    end)
  end

  defp access_badges(assigns) do
    ~H"""
    <div class="flex gap-1 items-center">
      <.badge :if={@info.role != :none} tone={role_tone(@info.role)} class="uppercase shrink-0">
        {Atom.to_string(@info.role)}
      </.badge>

      <.badge :if={@info.is_public} tone="neutral" class="uppercase shrink-0">
        <.icon name="hero-globe-alt" class="size-3 mr-1" />
        {gettext("Public")}
      </.badge>

      <.badge
        :if={!@info.is_public and @info.shares_count > 0 and @info.role == :owner}
        tone="info"
        class="shrink-0"
      >
        <.icon name="hero-users" class="size-3 mr-1" />
        {@info.shares_count}
      </.badge>
    </div>
    """
  end

  defp role_tone(:owner), do: "primary"
  defp role_tone(:writer), do: "secondary"
  defp role_tone(:reader), do: "accent"

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

  @impl true
  def render(assigns) do
    ~H"""
    <.page_container size="wide" class="space-y-6">
      <div class="flex justify-between items-center">
        <div>
          <h1 class="text-2xl font-display font-bold text-base-content">{gettext("Courses")}</h1>
          <p class="text-base-content/60">
            {gettext("Manage your educational content and materials.")}
          </p>
        </div>
        <.button
          :if={Identity.can?(@current_user, "courses.create")}
          patch={~p"/studio/courses/new?#{build_query_params(assigns, %{})}"}
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

      <% path_fn = fn overrides -> ~p"/studio/courses?#{build_query_params(assigns, overrides)}" end %>

      <.table id="courses" rows={@streams.courses} meta={@meta} path_fn={path_fn}>
        <:col :let={{_id, course}} label={gettext("Title")} sort="title">
          <div class="flex flex-col gap-1 items-start">
            <span class="font-bold">{course.title}</span>
            <.access_badges info={course_badges(course, @current_user)} />
          </div>
        </:col>
        <:col :let={{_id, course}} label={gettext("Code")} sort="code">
          <span class="text-sm font-mono text-base-content/70">
            {if course.code, do: course.code, else: "-"}
          </span>
        </:col>
        <:col :let={{_id, course}} label={gettext("Status")} sort="status">
          <div class="flex flex-col gap-1 items-start">
            <.badge tone={status_tone(course.status)}>
              {Atom.to_string(course.status) |> String.capitalize()}
            </.badge>

            <.badge :if={course.copy_status != :ready} tone={copy_status_tone(course.copy_status)}>
              <.icon
                :if={course.copy_status == :copying}
                name="hero-arrow-path"
                class="size-3 mr-1 animate-spin"
              />
              {if course.copy_status == :copying,
                do: gettext("Copying…"),
                else: gettext("Copy failed")}
            </.badge>
          </div>
        </:col>

        <:col :let={{_id, course}} label={gettext("Owner")}>
          <span class="text-sm font-medium text-base-content/80">
            {course.owner_login}
          </span>
        </:col>

        <:col :let={{_id, course}} label={gettext("Created At")} sort="inserted_at">
          <span class="text-sm opacity-60">{TimeZones.format(course.inserted_at, "%d.%m.%Y")}</span>
        </:col>
        <:action :let={{_id, course}}>
          <% info = course_badges(course, @current_user) %>
          <% can_edit =
            info.role in [:owner, :writer] or Identity.can?(@current_user, "courses.update", course) %>
          <% can_view = can_edit or info.role == :reader or info.is_public %>

          <div class="flex justify-end gap-2">
            <span
              :if={course.copy_status == :copying}
              class="btn btn-square btn-disabled"
              title={gettext("Copying in progress…")}
            >
              <.icon name="hero-arrow-path" class="size-4 animate-spin" />
            </span>

            <.icon_button
              :if={can_view && course.copy_status != :copying}
              navigate={~p"/studio/courses/#{course.id}/builder"}
              variant="primary"
              icon={if can_edit, do: "hero-wrench-screwdriver", else: "hero-eye"}
              label={if can_edit, do: gettext("Open Builder"), else: gettext("View Course")}
            />

            <.icon_button
              :if={can_edit && course.copy_status != :copying}
              patch={~p"/studio/courses/#{course.id}/edit?#{build_query_params(assigns, %{})}"}
              icon="hero-pencil-square"
              label={gettext("Edit Settings")}
            />

            <.icon_button
              :if={can_edit && course.copy_status != :copying}
              type="button"
              phx-click="share_click"
              phx-value-id={course.id}
              icon="hero-share"
              label={gettext("Share Access")}
            />

            <.icon_button
              :if={can_edit && course.copy_status != :copying}
              type="button"
              phx-click="enroll_click"
              phx-value-id={course.id}
              icon="hero-user-plus"
              label={gettext("Enroll Students")}
            />

            <.icon_button
              :if={can_edit && course.copy_status != :copying}
              type="button"
              phx-click="duplicate_click"
              phx-value-id={course.id}
              icon="hero-document-duplicate"
              label={gettext("Duplicate Course")}
            />

            <.icon_button
              :if={can_edit && course.copy_status == :failed}
              type="button"
              phx-click="retry_duplicate_click"
              phx-value-id={course.id}
              icon="hero-arrow-path"
              label={gettext("Retry Copy")}
            />

            <.icon_button
              :if={can_edit}
              type="button"
              phx-click="delete_click"
              phx-value-id={course.id}
              icon="hero-trash"
              label={gettext("Delete")}
              variant="danger"
            />
          </div>
        </:action>
      </.table>

      <.empty_state
        :if={@meta.total_count == 0}
        icon="hero-book-open"
        title={gettext("No courses yet")}
        description={gettext("Create one to get started.")}
      />

      <div class="flex justify-end">
        <.pagination meta={@meta} path_fn={path_fn} />
      </div>

      <.slide_over
        id="course-slideover"
        show={@live_action in [:new, :edit]}
        title={@page_title}
        on_close={JS.patch(~p"/studio/courses?#{build_query_params(assigns, %{})}")}
      >
        <.live_component
          :if={@course}
          module={CourseFormComponent}
          id={@course.id || :new}
          action={@live_action}
          course={@course}
          current_user={@current_user}
          patch={~p"/studio/courses?#{build_query_params(assigns, %{})}"}
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

      <.modal
        id="enroll-course-modal"
        show={@course_to_enroll != nil}
        title={
          gettext("Enroll Students: %{title}",
            title: if(@course_to_enroll, do: @course_to_enroll.title, else: "")
          )
        }
        on_cancel={JS.push("cancel_enroll")}
      >
        <.live_component
          :if={@course_to_enroll}
          module={CourseEnrollmentComponent}
          id={"enroll-#{@course_to_enroll.id}"}
          course={@course_to_enroll}
          current_user={@current_user}
        />
      </.modal>

      <.modal
        id="duplicate-course-modal"
        show={@course_to_duplicate != nil}
        title={
          gettext("Duplicate Course: %{title}",
            title: if(@course_to_duplicate, do: @course_to_duplicate.title, else: "")
          )
        }
        on_cancel={JS.push("cancel_duplicate")}
      >
        <form id="duplicate-course-form" phx-submit="confirm_duplicate" class="flex flex-col gap-4">
          <p class="text-sm text-base-content/70">
            {gettext(
              "This creates an independent copy of all sections, blocks, and files, as a background job. Cohorts already enrolled in the original course are unaffected and keep seeing their current material."
            )}
          </p>

          <div class="form-control w-full">
            <label class="label">
              <span class="label-text font-bold">{gettext("New Course Title")}</span>
            </label>
            <input
              type="text"
              name="title"
              value={@duplicate_title}
              class={["input input-bordered w-full", @duplicate_error && "input-error"]}
              autocomplete="off"
              autofocus
            />
            <p :if={@duplicate_error} class="mt-2 text-sm text-error font-bold">
              {@duplicate_error}
            </p>
          </div>

          <div class="flex justify-end gap-3 mt-2">
            <.button type="button" variant="ghost" phx-click="cancel_duplicate">
              {gettext("Cancel")}
            </.button>
            <.button type="submit" variant="primary">
              {gettext("Duplicate")}
            </.button>
          </div>
        </form>
      </.modal>
    </.page_container>
    """
  end

  defp status_tone(:published), do: "success"
  defp status_tone(:draft), do: "warning"
  defp status_tone(:archived), do: "error"

  defp copy_status_tone(:copying), do: "info"
  defp copy_status_tone(:failed), do: "error"

  defp changeset_error_message(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map_join("; ", fn {field, errors} -> "#{field} #{Enum.join(errors, ", ")}" end)
  end
end
