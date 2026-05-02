defmodule AthenaWeb.TeachingLive.CohortDetails do
  @moduledoc """
  LiveView for viewing a specific cohort and managing its students and courses.

  Displays cohort metadata, a list of assigned courses (enrollments), and a 
  paginated list of students (memberships). Integrates with slide-over components
  for adding new students and assigning courses.
  """
  use AthenaWeb, :live_view

  alias Athena.Learning
  alias AthenaWeb.TeachingLive.MembershipFormComponent
  alias AthenaWeb.TeachingLive.EnrollmentFormComponent

  on_mount {AthenaWeb.Hooks.Permission, "cohorts.read"}

  @doc """
  Initializes the LiveView by fetching the cohort and its non-paginated enrollments.
  """
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  @impl true
  def mount(%{"id" => id}, _session, socket) do
    user = socket.assigns.current_user

    case Learning.get_cohort(user, id) do
      {:ok, cohort} ->
        {:ok, {enrollments, _meta}} =
          Learning.list_cohort_enrollments(user, id, %{"page_size" => 50})

        {:ok,
         socket
         |> assign(:cohort, cohort)
         |> assign(:membership_to_delete, nil)
         |> assign(:enrollment_to_delete, nil)
         |> stream(:memberships, [])
         |> stream(:enrollments, enrollments)}

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
    flop_params = Map.put(params, "page_size", 20)

    case Learning.list_cohort_memberships(socket.assigns.cohort.id, flop_params) do
      {:ok, {memberships, meta}} ->
        socket =
          socket
          |> assign(meta: meta)
          |> stream(:memberships, memberships, reset: true)
          |> apply_action(socket.assigns.live_action, params)

        {:noreply, socket}

      {:error, _meta} ->
        {:noreply, push_patch(socket, to: ~p"/teaching/cohorts/#{socket.assigns.cohort.id}")}
    end
  end

  defp apply_action(socket, :index, _params) do
    assign(socket, page_title: socket.assigns.cohort.name)
  end

  defp apply_action(socket, :add_student, _params) do
    if Learning.can_manage_cohort_processes?(socket.assigns.current_user, socket.assigns.cohort) do
      assign(socket, page_title: gettext("Add Student to Cohort"))
    else
      socket
      |> put_flash(:error, gettext("You don't have permission to add students."))
      |> push_patch(to: ~p"/teaching/cohorts/#{socket.assigns.cohort.id}")
    end
  end

  defp apply_action(socket, :enroll_course, _params) do
    if Learning.can_manage_cohort_processes?(socket.assigns.current_user, socket.assigns.cohort) do
      assign(socket, page_title: gettext("Assign Course to Cohort"))
    else
      socket
      |> put_flash(:error, gettext("Permission denied."))
      |> push_patch(to: ~p"/teaching/cohorts/#{socket.assigns.cohort.id}")
    end
  end

  @doc """
  Handles UI events for initiating and confirming deletions of students or courses.
  """
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  @impl true
  def handle_event("delete_click", %{"id" => id}, socket) do
    if Learning.can_manage_cohort_processes?(socket.assigns.current_user, socket.assigns.cohort) do
      membership = Learning.get_cohort_membership!(id)
      {:noreply, assign(socket, membership_to_delete: membership)}
    else
      {:noreply, put_flash(socket, :error, gettext("Permission denied."))}
    end
  end

  def handle_event("confirm_delete", _, %{assigns: %{membership_to_delete: membership}} = socket) do
    case Learning.remove_student_from_cohort(membership) do
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
         |> assign(enrollment_to_delete: nil)}

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
    {:noreply, stream_insert(socket, :enrollments, reloaded)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-8">
      <div class="flex items-center gap-4">
        <.button navigate={~p"/teaching/cohorts"} class="btn btn-circle btn-ghost btn-sm">
          <.icon name="hero-arrow-left" class="size-5" />
        </.button>
        <div>
          <h1 class="text-2xl font-display font-bold text-base-content">{@cohort.name}</h1>
          <p class="text-base-content/60 text-sm">
            {gettext("Cohort Dashboard")}
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
        <:item title={gettext("Instructors")}>
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
            :if={Learning.Cohorts.can_manage_cohort_processes?(@current_user, @cohort)}
            patch={~p"/teaching/cohorts/#{@cohort.id}/enroll_course"}
            class="btn btn-primary btn-sm"
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
            <span class={[
              "badge badge-sm font-bold",
              enrollment.status == :active && "badge-success badge-soft",
              enrollment.status == :completed && "badge-info badge-soft",
              enrollment.status == :dropped && "badge-error badge-soft"
            ]}>
              {Atom.to_string(enrollment.status) |> String.capitalize()}
            </span>
          </:col>
          <:col :let={{_id, enrollment}} label={gettext("Assigned At")}>
            <span class="text-sm opacity-60">
              {Calendar.strftime(enrollment.inserted_at, "%d.%m.%Y")}
            </span>
          </:col>
          <:action :let={{_id, enrollment}}>
            <div class="flex items-center gap-2 justify-end">
              <.link
                :if={Learning.Cohorts.can_view_cohort_processes?(@current_user, @cohort)}
                navigate={~p"/teaching/cohorts/#{@cohort.id}/access/#{enrollment.course.id}"}
                class="btn btn-ghost btn-xs text-primary hover:bg-primary/10"
                title={gettext("Access Settings")}
              >
                <.icon name="hero-key" class="size-4" />
                <span class="hidden sm:inline">{gettext("Access")}</span>
              </.link>

              <button
                :if={Learning.Cohorts.can_manage_cohort_processes?(@current_user, @cohort)}
                type="button"
                phx-click="delete_enrollment_click"
                phx-value-id={enrollment.id}
                class="btn btn-ghost btn-xs btn-square text-error hover:bg-error/10"
                title={gettext("Remove Assignment")}
              >
                <.icon name="hero-x-mark" class="size-4" />
              </button>
            </div>
          </:action>
        </.table>
      </div>

      <div class="space-y-4">
        <div class="flex justify-between items-center">
          <h2 class="text-xl font-display font-bold">{gettext("Students")}</h2>
          <.button
            :if={Learning.Cohorts.can_manage_cohort_processes?(@current_user, @cohort)}
            patch={~p"/teaching/cohorts/#{@cohort.id}/add_student"}
            class="btn btn-primary btn-sm"
          >
            <.icon name="hero-user-plus" class="size-4" />
            {gettext("Add Student")}
          </.button>
        </div>

        <.table id="memberships" rows={@streams.memberships}>
          <:col :let={{_id, membership}} label={gettext("Login")}>
            <span class="font-bold">{membership.account.login}</span>
          </:col>
          <:col :let={{_id, membership}} label={gettext("Joined At")}>
            <span class="text-sm opacity-60">
              {Calendar.strftime(membership.inserted_at, "%d.%m.%Y")}
            </span>
          </:col>
          <:action :let={{_id, membership}}>
            <div class="flex justify-end">
              <.button
                :if={Learning.Cohorts.can_manage_cohort_processes?(@current_user, @cohort)}
                type="button"
                phx-click="delete_click"
                phx-value-id={membership.id}
                class="btn btn-ghost btn-xs btn-square text-error hover:bg-error/10"
                title={gettext("Remove")}
              >
                <.icon name="hero-x-mark" class="size-4" />
              </.button>
            </div>
          </:action>
        </.table>

        <div class="flex justify-end">
          <.pagination
            meta={@meta}
            path_fn={fn p -> ~p"/teaching/cohorts/#{@cohort.id}?#{%{"page" => p}}" end}
          />
        </div>
      </div>

      <.slide_over
        id="membership-slideover"
        show={@live_action == :add_student}
        title={@page_title}
        on_close={JS.patch(~p"/teaching/cohorts/#{@cohort.id}")}
      >
        <.live_component
          module={MembershipFormComponent}
          id="new-membership"
          cohort_id={@cohort.id}
          current_user={@current_user}
          patch={~p"/teaching/cohorts/#{@cohort.id}"}
        />
      </.slide_over>

      <.slide_over
        id="enrollment-slideover"
        show={@live_action == :enroll_course}
        title={@page_title}
        on_close={JS.patch(~p"/teaching/cohorts/#{@cohort.id}")}
      >
        <.live_component
          module={EnrollmentFormComponent}
          id="new-enrollment"
          cohort_id={@cohort.id}
          current_user={@current_user}
          patch={~p"/teaching/cohorts/#{@cohort.id}"}
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
end
