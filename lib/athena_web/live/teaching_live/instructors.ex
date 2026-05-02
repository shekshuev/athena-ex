defmodule AthenaWeb.TeachingLive.Instructors do
  @moduledoc """
  LiveView for managing instructors.

  Displays a paginated and searchable list of instructors using Streams for optimal
  DOM diffing. Handles instructor deletion and integrates with `InstructorFormComponent`
  for creating and editing profiles via a slide-over.
  """
  use AthenaWeb, :live_view

  alias Athena.Learning
  alias Athena.Learning.Instructor
  alias Athena.Identity
  alias AthenaWeb.TeachingLive.InstructorFormComponent

  on_mount {AthenaWeb.Hooks.Permission, "instructors.read"}

  @doc """
  Initializes the LiveView, setting up the instructors stream and default assigns.
  """
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(instructor_to_delete: nil)
     |> stream(:instructors, [])}
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

    case Learning.list_instructors(socket.assigns.current_user, flop_params) do
      {:ok, {instructors, meta}} ->
        socket =
          socket
          |> assign(meta: meta, search: search)
          |> stream(:instructors, instructors, reset: true)
          |> apply_action(socket.assigns.live_action, params)

        {:noreply, socket}

      {:error, _meta} ->
        {:noreply, push_patch(socket, to: ~p"/teaching/instructors")}
    end
  end

  defp apply_action(socket, :index, _params) do
    assign(socket, page_title: gettext("Instructors"), instructor: nil)
  end

  defp apply_action(socket, :new, _params) do
    if Identity.can?(socket.assigns.current_user, "instructors.create") do
      assign(socket, page_title: gettext("Create Instructor"), instructor: %Instructor{})
    else
      socket
      |> put_flash(:error, gettext("You don't have permission to create instructors."))
      |> push_patch(to: ~p"/teaching/instructors")
    end
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    {:ok, instructor} = Learning.get_instructor(socket.assigns.current_user, id)

    if Identity.can?(socket.assigns.current_user, "instructors.update", instructor) do
      assign(socket, page_title: gettext("Edit Instructor"), instructor: instructor)
    else
      socket
      |> put_flash(:error, gettext("You don't have permission to edit this profile."))
      |> push_patch(to: ~p"/teaching/instructors")
    end
  end

  @doc """
  Handles UI events such as searching and instructor deletion confirmations.
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

    {:noreply, push_patch(socket, to: ~p"/teaching/instructors?#{params}")}
  end

  def handle_event("delete_click", %{"id" => id}, socket) do
    {:ok, instructor} = Learning.get_instructor(socket.assigns.current_user, id)

    if Identity.can?(socket.assigns.current_user, "instructors.delete", instructor) do
      {:noreply, assign(socket, instructor_to_delete: instructor)}
    else
      {:noreply,
       socket
       |> put_flash(:error, gettext("You don't have permission to delete this profile."))
       |> push_patch(to: ~p"/teaching/instructors")}
    end
  end

  def handle_event("confirm_delete", _, %{assigns: %{instructor_to_delete: instructor}} = socket) do
    case Learning.delete_instructor(socket.assigns.current_user, instructor) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Instructor deleted successfully"))
         |> stream_delete(:instructors, instructor)
         |> assign(instructor_to_delete: nil)}

      {:error, _} ->
        {:noreply, socket |> put_flash(:error, gettext("Failed to delete instructor"))}
    end
  end

  def handle_event("cancel_delete", _, socket) do
    {:noreply, assign(socket, instructor_to_delete: nil)}
  end

  @doc """
  Handles messages from child components, such as a successfully saved instructor.
  """
  @spec handle_info(term(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  @impl true
  def handle_info({InstructorFormComponent, {:saved, instructor}}, socket) do
    {:ok, reloaded} = Learning.get_instructor(socket.assigns.current_user, instructor.id)
    {:noreply, stream_insert(socket, :instructors, reloaded)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex justify-between items-center">
        <div>
          <h1 class="text-2xl font-display font-bold text-base-content">{gettext("Instructors")}</h1>
          <p class="text-base-content/60">
            {gettext("Manage teaching staff and their profiles.")}
          </p>
        </div>
        <.button
          :if={Identity.can?(@current_user, "instructors.create")}
          patch={~p"/teaching/instructors/new"}
          class="btn btn-primary"
        >
          <.icon name="hero-plus" class="size-5" />
          {gettext("Add Instructor")}
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
              placeholder={gettext("Search by title...")}
              class="input input-bordered w-full pl-10"
              phx-debounce="500"
            />
          </div>
        </.form>
      </div>

      <.table id="instructors" rows={@streams.instructors}>
        <:col :let={{_id, instructor}} label={gettext("User")}>
          <span class="font-bold text-primary">
            {if instructor.account, do: instructor.account.login, else: gettext("Unknown")}
          </span>
        </:col>
        <:col :let={{_id, instructor}} label={gettext("Title")}>
          <span class="font-medium">{instructor.title}</span>
        </:col>
        <:col :let={{_id, instructor}} label={gettext("Created At")}>
          <span class="text-sm opacity-60">
            {Calendar.strftime(instructor.inserted_at, "%d.%m.%Y")}
          </span>
        </:col>
        <:action :let={{_id, instructor}}>
          <div class="flex justify-end gap-2">
            <.button
              :if={Identity.can?(@current_user, "instructors.update", instructor)}
              patch={~p"/teaching/instructors/#{instructor.id}/edit"}
              class="btn btn-ghost btn-xs btn-square"
              title={gettext("Edit")}
            >
              <.icon name="hero-pencil-square" class="size-4" />
            </.button>

            <.button
              :if={Identity.can?(@current_user, "instructors.delete", instructor)}
              type="button"
              phx-click="delete_click"
              phx-value-id={instructor.id}
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
          path_fn={fn p -> ~p"/teaching/instructors?#{%{"page" => p, "search" => @search}}" end}
        />
      </div>

      <.slide_over
        id="instructor-slideover"
        show={@live_action in [:new, :edit]}
        title={@page_title}
        on_close={JS.patch(~p"/teaching/instructors")}
      >
        <.live_component
          :if={@instructor}
          module={InstructorFormComponent}
          id={@instructor.id || :new}
          action={@live_action}
          instructor={@instructor}
          current_user={@current_user}
          patch={~p"/teaching/instructors"}
        />
      </.slide_over>

      <.modal
        id="delete-instructor-modal"
        show={@instructor_to_delete != nil}
        title={gettext("Delete Instructor")}
        description={
          gettext(
            "Are you sure you want to remove this instructor profile? This action cannot be undone."
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
end
