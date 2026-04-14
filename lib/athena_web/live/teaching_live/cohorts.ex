defmodule AthenaWeb.TeachingLive.Cohorts do
  @moduledoc """
  LiveView for managing student cohorts.

  Displays a paginated and searchable list of cohorts using Streams for optimal
  DOM diffing. Handles cohort deletion and integrates with `CohortFormComponent`
  for creating and editing groups via a slide-over.
  """
  use AthenaWeb, :live_view

  alias Athena.Learning
  alias Athena.Learning.Cohort
  alias Athena.Identity
  alias AthenaWeb.TeachingLive.CohortFormComponent

  on_mount {AthenaWeb.Hooks.Permission, "cohorts.read"}

  @doc """
  Initializes the LiveView, setting up the cohorts stream and default assigns.
  """
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(cohort_to_delete: nil)
     |> stream(:cohorts, [])}
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
          "0" => %{"field" => "name", "op" => "ilike_and", "value" => search}
        })
      else
        params
      end

    case Learning.list_cohorts(socket.assigns.current_user, flop_params) do
      {:ok, {cohorts, meta}} ->
        socket =
          socket
          |> assign(meta: meta, search: search)
          |> stream(:cohorts, cohorts, reset: true)
          |> apply_action(socket.assigns.live_action, params)

        {:noreply, socket}

      {:error, _meta} ->
        {:noreply, push_patch(socket, to: ~p"/teaching/cohorts")}
    end
  end

  defp apply_action(socket, :index, _params) do
    assign(socket, page_title: gettext("Cohorts"), cohort: nil)
  end

  defp apply_action(socket, :new, _params) do
    if Identity.can?(socket.assigns.current_user, "cohorts.create") do
      assign(socket, page_title: gettext("Create Cohort"), cohort: %Cohort{})
    else
      socket
      |> put_flash(:error, gettext("You don't have permission to create cohorts."))
      |> push_patch(to: ~p"/teaching/cohorts")
    end
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    if Identity.can?(socket.assigns.current_user, "cohorts.update") do
      {:ok, cohort} = Learning.get_cohort(socket.assigns.current_user, id)
      assign(socket, page_title: gettext("Edit Cohort"), cohort: cohort)
    else
      socket
      |> put_flash(:error, gettext("You don't have permission to edit cohorts."))
      |> push_patch(to: ~p"/teaching/cohorts")
    end
  end

  @doc """
  Handles UI events such as searching and cohort deletion confirmations.
  """
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  @impl true
  def handle_event("search", %{"search" => search}, socket) do
    params = %{"search" => search, "page" => 1, "page_size" => socket.assigns.meta.page_size}
    {:noreply, push_patch(socket, to: ~p"/teaching/cohorts?#{params}")}
  end

  def handle_event("delete_click", %{"id" => id}, socket) do
    if Identity.can?(socket.assigns.current_user, "cohorts.delete") do
      {:ok, cohort} = Learning.get_cohort(socket.assigns.current_user, id)
      {:noreply, assign(socket, cohort_to_delete: cohort)}
    else
      {:noreply,
       socket
       |> put_flash(:error, gettext("You don't have permission to delete cohorts."))
       |> push_patch(to: ~p"/teaching/cohorts")}
    end
  end

  def handle_event("confirm_delete", _, %{assigns: %{cohort_to_delete: cohort}} = socket) do
    case Learning.delete_cohort(cohort) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Cohort deleted successfully"))
         |> stream_delete(:cohorts, cohort)
         |> assign(cohort_to_delete: nil)}

      {:error, _} ->
        {:noreply, socket |> put_flash(:error, gettext("Failed to delete cohort"))}
    end
  end

  def handle_event("cancel_delete", _, socket) do
    {:noreply, assign(socket, cohort_to_delete: nil)}
  end

  @doc """
  Handles messages from child components, such as a successfully saved cohort.
  """
  @spec handle_info(term(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  @impl true
  def handle_info({CohortFormComponent, {:saved, cohort}}, socket) do
    {:ok, reloaded} = Learning.get_cohort(socket.assigns.current_user, cohort.id)
    {:noreply, stream_insert(socket, :cohorts, reloaded)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex justify-between items-center">
        <div>
          <h1 class="text-2xl font-display font-bold text-base-content">{gettext("Cohorts")}</h1>
          <p class="text-base-content/60">
            {gettext("Manage student groups and academic flows.")}
          </p>
        </div>
        <.button
          :if={Identity.can?(@current_user, "cohorts.create")}
          patch={~p"/teaching/cohorts/new"}
          class="btn btn-primary"
        >
          <.icon name="hero-plus" class="size-5" />
          {gettext("Add Cohort")}
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
              placeholder={gettext("Search by name...")}
              class="input input-bordered w-full pl-10"
              phx-debounce="500"
            />
          </div>
        </.form>
      </div>

      <.table id="cohorts" rows={@streams.cohorts}>
        <:col :let={{_id, cohort}} label={gettext("Name")}>
          <span class="font-bold text-primary">{cohort.name}</span>
        </:col>
        <:col :let={{_id, cohort}} label={gettext("Instructors")}>
          <div class="flex flex-col gap-1">
            <%= if cohort.instructors == [] do %>
              <span class="text-sm opacity-50 italic">{gettext("No instructors")}</span>
            <% else %>
              <%= for instructor <- cohort.instructors do %>
                <span class="badge badge-sm badge-neutral badge-soft">
                  {instructor.account.login}
                </span>
              <% end %>
            <% end %>
          </div>
        </:col>
        <:col :let={{_id, cohort}} label={gettext("Created")}>
          <span class="text-sm opacity-60">
            {Calendar.strftime(cohort.inserted_at, "%d.%m.%Y")}
          </span>
        </:col>
        <:action :let={{_id, cohort}}>
          <div class="flex justify-end gap-2">
            <.button
              navigate={~p"/teaching/cohorts/#{cohort.id}"}
              class="btn btn-ghost btn-xs btn-square"
              title={gettext("View Details")}
            >
              <.icon name="hero-eye" class="size-4" />
            </.button>

            <.button
              :if={Identity.can?(@current_user, "cohorts.update")}
              patch={~p"/teaching/cohorts/#{cohort.id}/edit"}
              class="btn btn-ghost btn-xs btn-square"
              title={gettext("Edit")}
            >
              <.icon name="hero-pencil-square" class="size-4" />
            </.button>

            <.button
              :if={Identity.can?(@current_user, "cohorts.delete")}
              type="button"
              phx-click="delete_click"
              phx-value-id={cohort.id}
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
          path_fn={fn p -> ~p"/teaching/cohorts?#{%{"page" => p, "search" => @search}}" end}
        />
      </div>

      <.slide_over
        id="cohort-slideover"
        show={@live_action in [:new, :edit]}
        title={@page_title}
        on_close={JS.patch(~p"/teaching/cohorts")}
      >
        <.live_component
          :if={@cohort}
          module={CohortFormComponent}
          id={@cohort.id || :new}
          action={@live_action}
          cohort={@cohort}
          patch={~p"/teaching/cohorts"}
        />
      </.slide_over>

      <.modal
        id="delete-cohort-modal"
        show={@cohort_to_delete != nil}
        title={gettext("Delete Cohort")}
        description={
          gettext(
            "Are you sure you want to delete this cohort? All student enrollments associated with this group will also be removed."
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
