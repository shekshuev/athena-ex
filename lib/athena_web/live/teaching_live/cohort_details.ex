defmodule AthenaWeb.TeachingLive.CohortDetails do
  @moduledoc """
  LiveView for viewing a specific cohort/team and managing its students/members and courses.

  Displays cohort metadata, a list of assigned courses (enrollments), and a
  paginated list of students (memberships). Integrates with slide-over components
  for adding new students and assigning courses.

  Shared by both `/teaching/cohorts/:id` (academic cohorts) and
  `/teaching/teams/:id` (competition teams) - same schema and context calls,
  the loaded `@cohort.type` just switches which base path and which copy
  ("Cohort"/"Team", "Student"/"Member") is used.
  """
  use AthenaWeb, :live_view

  alias Athena.{Identity, Learning}
  alias AthenaWeb.TeachingLive.MembershipFormComponent
  alias AthenaWeb.TeachingLive.EnrollmentFormComponent

  on_mount {AthenaWeb.Hooks.Permission, ["cohorts.read", "teams.read"]}

  @doc """
  Initializes the LiveView by fetching the cohort and its non-paginated enrollments.
  """
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  @impl true
  def mount(%{"id" => id}, _session, socket) do
    user = socket.assigns.current_user

    case Learning.get_cohort(user, id) do
      {:ok, cohort} ->
        if Learning.can_view_cohort_processes?(user, cohort) do
          {:ok, {enrollments, _meta}} =
            Learning.list_cohort_enrollments(user, id, %{"page_size" => 50})

          {:ok,
           socket
           |> assign(:cohort, cohort)
           |> assign(:membership_to_delete, nil)
           |> assign(:enrollment_to_delete, nil)
           |> assign(:enrollments_count, length(enrollments))
           |> stream(:memberships, [])
           |> stream(:enrollments, enrollments)}
        else
          {:ok, push_navigate(socket, to: index_path(cohort))}
        end

      {:error, :not_found} ->
        {:ok, push_navigate(socket, to: ~p"/teaching/cohorts")}
    end
  end

  @doc """
  Handles URL parameters, fetching the paginated list of students and setting live actions.
  """
  @spec handle_params(map(), String.t(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  @impl true
  def handle_params(params, _url, socket) do
    flop_params = Map.put_new(params, "page_size", 20)

    case Learning.list_cohort_memberships(socket.assigns.cohort.id, flop_params) do
      {:ok, {memberships, meta}} ->
        socket =
          socket
          |> assign(meta: meta)
          |> stream(:memberships, memberships, reset: true)
          |> apply_action(socket.assigns.live_action, params)

        {:noreply, socket}

      {:error, _meta} ->
        {:noreply, push_patch(socket, to: show_path(socket.assigns.cohort, %{}))}
    end
  end

  defp apply_action(socket, :index, _params) do
    assign(socket, page_title: socket.assigns.cohort.name)
  end

  defp apply_action(socket, :add_student, _params) do
    cohort = socket.assigns.cohort

    if Learning.can_manage_cohort_processes?(socket.assigns.current_user, cohort) do
      title =
        if cohort.type == :team,
          do: gettext("Add Member to Team"),
          else: gettext("Add Student to Cohort")

      assign(socket, page_title: title)
    else
      socket
      |> put_flash(:error, gettext("You don't have permission to add students."))
      |> push_patch(to: show_path(cohort, %{}))
    end
  end

  defp apply_action(socket, :enroll_course, _params) do
    cohort = socket.assigns.cohort

    if Learning.can_manage_cohort_processes?(socket.assigns.current_user, cohort) do
      title =
        if cohort.type == :team,
          do: gettext("Assign Course to Team"),
          else: gettext("Assign Course to Cohort")

      assign(socket, page_title: title)
    else
      socket
      |> put_flash(:error, gettext("Permission denied."))
      |> push_patch(to: show_path(cohort, %{}))
    end
  end

  @doc """
  Handles UI events for initiating and confirming deletions of students or courses.
  """
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  @impl true
  def handle_event("update_page_size", %{"page_size" => size}, socket) do
    params = build_query_params(socket.assigns, %{"page_size" => size, "page" => 1})

    {:noreply, push_patch(socket, to: show_path(socket.assigns.cohort, params))}
  end

  def handle_event("delete_click", %{"id" => id}, socket) do
    if Learning.can_manage_cohort_processes?(socket.assigns.current_user, socket.assigns.cohort) do
      membership = Learning.get_cohort_membership!(id)
      {:noreply, assign(socket, membership_to_delete: membership)}
    else
      {:noreply, put_flash(socket, :error, gettext("Permission denied."))}
    end
  end

  def handle_event("confirm_delete", _, %{assigns: %{membership_to_delete: membership}} = socket) do
    case Learning.remove_student_from_cohort(socket.assigns.current_user, membership) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Student removed from cohort."))
         |> stream_delete(:memberships, membership)
         |> assign(membership_to_delete: nil)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to remove student."))}
    end
  end

  def handle_event("cancel_delete", _, socket) do
    {:noreply, assign(socket, membership_to_delete: nil)}
  end

  def handle_event("delete_enrollment_click", %{"id" => id}, socket) do
    enrollment = Learning.get_enrollment!(socket.assigns.current_user, id)

    if Learning.can_manage_cohort_processes?(socket.assigns.current_user, socket.assigns.cohort) do
      {:noreply, assign(socket, enrollment_to_delete: enrollment)}
    else
      {:noreply, put_flash(socket, :error, gettext("Permission denied."))}
    end
  end

  def handle_event(
        "confirm_delete_enrollment",
        _,
        %{assigns: %{enrollment_to_delete: enrollment}} = socket
      ) do
    case Learning.delete_enrollment(socket.assigns.current_user, enrollment) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Course assignment removed."))
         |> stream_delete(:enrollments, enrollment)
         |> assign(
           enrollment_to_delete: nil,
           enrollments_count: socket.assigns.enrollments_count - 1
         )}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to remove assignment."))}
    end
  end

  def handle_event("cancel_delete_enrollment", _, socket) do
    {:noreply, assign(socket, enrollment_to_delete: nil)}
  end

  @doc """
  Handles successful creation messages from child components.
  """
  @spec handle_info(term(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  @impl true
  def handle_info({MembershipFormComponent, {:saved, membership}}, socket) do
    reloaded = Learning.get_cohort_membership!(membership.id)
    {:noreply, stream_insert(socket, :memberships, reloaded)}
  end

  def handle_info({EnrollmentFormComponent, {:saved, enrollment}}, socket) do
    reloaded = Learning.get_enrollment!(socket.assigns.current_user, enrollment.id)

    {:noreply,
     socket
     |> stream_insert(:enrollments, reloaded)
     |> assign(:enrollments_count, socket.assigns.enrollments_count + 1)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-8">
      <div class="flex items-center gap-4">
        <.button navigate={index_path(@cohort)} class="btn btn-circle btn-ghost btn-sm">
          <.icon name="hero-arrow-left" class="size-5" />
        </.button>
        <div>
          <h1 class="text-2xl font-display font-bold text-base-content">{@cohort.name}</h1>
          <p class="text-base-content/60 text-sm">
            {if @cohort.type == :team,
              do: gettext("Team Dashboard"),
              else: gettext("Cohort Dashboard")}
          </p>
        </div>
      </div>

      <h2 class="card-title text-xl mb-4">{gettext("Overview")}</h2>
      <.list>
        <:item title={gettext("Description")}>
          {if @cohort.description && @cohort.description != "",
            do: @cohort.description,
            else: "—"}
        </:item>
        <:item title={if @cohort.type == :team, do: gettext("Coaches"), else: gettext("Instructors")}>
          <div class="flex flex-wrap gap-2">
            <%= if @cohort.instructors == [] do %>
              <span class="italic opacity-50">{gettext("None assigned")}</span>
            <% else %>
              <%= for inst <- @cohort.instructors do %>
                <span class="badge badge-primary badge-soft font-bold">
                  {if inst.account, do: inst.account.login, else: gettext("Unknown")}
                </span>
              <% end %>
            <% end %>
          </div>
        </:item>
      </.list>

      <div class="space-y-4">
        <div class="flex justify-between items-center">
          <h2 class="text-xl font-display font-bold">{gettext("Assigned Courses")}</h2>
          <.button
            :if={Learning.can_manage_cohort_processes?(@current_user, @cohort)}
            variant="primary"
            size="sm"
            patch={enroll_course_path(@cohort, build_query_params(assigns, %{}))}
          >
            <.icon name="hero-book-open" class="size-4" />
            {gettext("Assign Course")}
          </.button>
        </div>

        <.table id="enrollments" rows={@streams.enrollments}>
          <:col :let={{_id, enrollment}} label={gettext("Course Title")}>
            <span class="font-bold">
              {if enrollment.course, do: enrollment.course.title, else: gettext("Unknown/Deleted")}
            </span>
          </:col>
          <:col :let={{_id, enrollment}} label={gettext("Status")}>
            <.badge tone={enrollment_status_tone(enrollment.status)}>
              {Atom.to_string(enrollment.status) |> String.capitalize()}
            </.badge>
          </:col>
          <:col :let={{_id, enrollment}} label={gettext("Assigned At")}>
            <span class="text-sm opacity-60">
              {TimeZones.format(enrollment.inserted_at, "%d.%m.%Y")}
            </span>
          </:col>
          <:action :let={{_id, enrollment}}>
            <div class="flex items-center gap-2 justify-end">
              <.button
                :if={Learning.can_view_cohort_processes?(@current_user, @cohort)}
                variant="ghost"
                size="xs"
                class="text-primary hover:bg-primary/10"
                navigate={access_path(@cohort, enrollment.course.id)}
              >
                <.icon name="hero-key" class="size-4" />
                <span class="hidden sm:inline">{gettext("Access")}</span>
              </.button>

              <.button
                :if={Identity.can?(@current_user, "engagement.read")}
                variant="ghost"
                size="xs"
                class="text-primary hover:bg-primary/10"
                navigate={engagement_path(@cohort, enrollment.course.id)}
              >
                <.icon name="hero-chart-bar" class="size-4" />
                <span class="hidden sm:inline">{gettext("Engagement")}</span>
              </.button>

              <.icon_button
                :if={Learning.can_manage_cohort_processes?(@current_user, @cohort)}
                type="button"
                phx-click="delete_enrollment_click"
                phx-value-id={enrollment.id}
                icon="hero-x-mark"
                label={gettext("Remove Assignment")}
                variant="danger"
              />
            </div>
          </:action>
        </.table>

        <.empty_state
          :if={@enrollments_count == 0}
          icon="hero-book-open"
          title={gettext("No courses assigned yet")}
        />
      </div>

      <div class="space-y-4">
        <div class="flex justify-between items-center">
          <h2 class="text-xl font-display font-bold">
            {if @cohort.type == :team, do: gettext("Members"), else: gettext("Students")}
          </h2>
          <.button
            :if={Learning.can_manage_cohort_processes?(@current_user, @cohort)}
            variant="primary"
            size="sm"
            patch={add_student_path(@cohort, build_query_params(assigns, %{}))}
          >
            <.icon name="hero-user-plus" class="size-4" />
            {if @cohort.type == :team, do: gettext("Add Member"), else: gettext("Add Student")}
          </.button>
        </div>

        <% path_fn = fn overrides -> show_path(@cohort, build_query_params(assigns, overrides)) end %>

        <.table id="memberships" rows={@streams.memberships} meta={@meta} path_fn={path_fn}>
          <:col :let={{_id, membership}} label={gettext("Login")}>
            <span class="font-bold">{membership.account.login}</span>
          </:col>
          <:col :let={{_id, membership}} label={gettext("Joined At")} sort="inserted_at">
            <span class="text-sm opacity-60">
              {TimeZones.format(membership.inserted_at, "%d.%m.%Y")}
            </span>
          </:col>
          <:action :let={{_id, membership}}>
            <div class="flex justify-end">
              <.icon_button
                :if={Learning.can_manage_cohort_processes?(@current_user, @cohort)}
                type="button"
                phx-click="delete_click"
                phx-value-id={membership.id}
                icon="hero-x-mark"
                label={gettext("Remove")}
                variant="danger"
              />
            </div>
          </:action>
        </.table>

        <.empty_state
          :if={@meta.total_count == 0}
          icon="hero-users"
          title={
            if @cohort.type == :team, do: gettext("No members yet"), else: gettext("No students yet")
          }
        />

        <div class="flex justify-end">
          <.pagination meta={@meta} path_fn={path_fn} />
        </div>
      </div>

      <.slide_over
        id="membership-slideover"
        show={@live_action == :add_student}
        title={@page_title}
        on_close={JS.patch(show_path(@cohort, build_query_params(assigns, %{})))}
      >
        <.live_component
          module={MembershipFormComponent}
          id="new-membership"
          cohort_id={@cohort.id}
          current_user={@current_user}
          patch={show_path(@cohort, build_query_params(assigns, %{}))}
        />
      </.slide_over>

      <.slide_over
        id="enrollment-slideover"
        show={@live_action == :enroll_course}
        title={@page_title}
        on_close={JS.patch(show_path(@cohort, build_query_params(assigns, %{})))}
      >
        <.live_component
          module={EnrollmentFormComponent}
          id="new-enrollment"
          cohort_id={@cohort.id}
          current_user={@current_user}
          patch={show_path(@cohort, build_query_params(assigns, %{}))}
        />
      </.slide_over>

      <.modal
        id="delete-membership-modal"
        show={@membership_to_delete != nil}
        title={gettext("Remove Student")}
        description={gettext("Are you sure you want to remove this student from the cohort?")}
        confirm_label={gettext("Remove")}
        danger={true}
        on_cancel={JS.push("cancel_delete")}
        on_confirm={JS.push("confirm_delete")}
      />

      <.modal
        id="delete-enrollment-modal"
        show={@enrollment_to_delete != nil}
        title={gettext("Remove Course Assignment")}
        description={
          gettext(
            "Are you sure you want to remove this course from the cohort? Students will lose access to its materials."
          )
        }
        confirm_label={gettext("Remove")}
        danger={true}
        on_cancel={JS.push("cancel_delete_enrollment")}
        on_confirm={JS.push("confirm_delete_enrollment")}
      />
    </div>
    """
  end

  # Type-aware path helpers - `CohortDetails` is mounted from both
  # `/teaching/cohorts/:id/...` (academic) and `/teaching/teams/:id/...`
  # (team) routes, so every link/redirect must stay on whichever side the
  # loaded `@cohort.type` actually belongs to.
  defp index_path(%{type: :team}), do: ~p"/teaching/teams"
  defp index_path(_cohort), do: ~p"/teaching/cohorts"

  defp show_path(%{type: :team, id: id}, query), do: ~p"/teaching/teams/#{id}?#{query}"
  defp show_path(%{id: id}, query), do: ~p"/teaching/cohorts/#{id}?#{query}"

  defp add_student_path(%{type: :team, id: id}, query),
    do: ~p"/teaching/teams/#{id}/add_student?#{query}"

  defp add_student_path(%{id: id}, query), do: ~p"/teaching/cohorts/#{id}/add_student?#{query}"

  defp enroll_course_path(%{type: :team, id: id}, query),
    do: ~p"/teaching/teams/#{id}/enroll_course?#{query}"

  defp enroll_course_path(%{id: id}, query),
    do: ~p"/teaching/cohorts/#{id}/enroll_course?#{query}"

  defp access_path(%{type: :team, id: id}, course_id),
    do: ~p"/teaching/teams/#{id}/access/#{course_id}"

  defp access_path(%{id: id}, course_id), do: ~p"/teaching/cohorts/#{id}/access/#{course_id}"

  defp engagement_path(%{type: :team, id: id}, course_id),
    do: ~p"/teaching/teams/#{id}/engagement/#{course_id}"

  defp engagement_path(%{id: id}, course_id),
    do: ~p"/teaching/cohorts/#{id}/engagement/#{course_id}"

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
      "page" => meta.current_page,
      "page_size" => meta.page_size,
      "order_by" => order_by,
      "order_directions" => order_directions
    }
    |> Map.merge(overrides)
    |> Enum.reject(fn {_, v} -> is_nil(v) or v == "" or v == [] end)
    |> Map.new()
  end

  defp enrollment_status_tone(:active), do: "success"
  defp enrollment_status_tone(:completed), do: "info"
  defp enrollment_status_tone(:dropped), do: "error"
end
