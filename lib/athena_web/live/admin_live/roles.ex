defmodule AthenaWeb.AdminLive.Roles do
  @moduledoc """
  LiveView for managing system roles and permissions.

  Displays a paginated and searchable list of roles using Streams for optimal
  DOM diffing. Handles role deletion and integrates with `RoleFormComponent`
  for creating and editing roles via a slide-over.
  """
  use AthenaWeb, :live_view

  alias Athena.Identity
  alias Athena.Identity.{Roles, Role}
  alias AthenaWeb.AdminLive.RoleFormComponent

  on_mount {AthenaWeb.Hooks.Permission, "roles.read"}

  @doc """
  Initializes the LiveView, setting up the roles stream and default assigns.
  """
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(role_to_delete: nil)
     |> stream(:roles, [])}
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

    case Roles.list_roles(flop_params) do
      {:ok, {roles, meta}} ->
        socket =
          socket
          |> assign(meta: meta, search: search)
          |> stream(:roles, roles, reset: true)
          |> apply_action(socket.assigns.live_action, params)

        {:noreply, socket}

      {:error, _meta} ->
        {:noreply, push_patch(socket, to: ~p"/admin/roles")}
    end
  end

  defp apply_action(socket, :index, _params) do
    assign(socket, page_title: gettext("Roles"), role: nil)
  end

  defp apply_action(socket, :new, _params) do
    if Identity.can?(socket.assigns.current_user, "roles.create") do
      assign(socket, page_title: gettext("Create Role"), role: %Role{})
    else
      socket
      |> put_flash(:error, gettext("You don't have permission to create roles."))
      |> push_patch(to: ~p"/admin/roles")
    end
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    if Identity.can?(socket.assigns.current_user, "roles.update") do
      case Roles.get_role(id) do
        {:ok, role} -> assign(socket, page_title: gettext("Edit Role"), role: role)
        _ -> push_patch(socket, to: ~p"/admin/roles")
      end
    else
      socket
      |> put_flash(:error, gettext("You don't have permission to edit roles."))
      |> push_patch(to: ~p"/admin/roles")
    end
  end

  @doc """
  Handles UI events such as searching and role deletion confirmations.
  """
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  @impl true
  def handle_event("search", %{"search" => search}, socket) do
    params =
      %{
        "search" => search,
        "page" => 1,
        "page_size" => socket.assigns.meta.page_size,
        "order_by" => socket.assigns.meta.flop.order_by,
        "order_directions" => socket.assigns.meta.flop.order_directions
      }
      |> Enum.reject(fn {_, v} -> v in [nil, "", []] end)
      |> Map.new()

    {:noreply, push_patch(socket, to: ~p"/admin/roles?#{params}")}
  end

  def handle_event("delete_click", %{"id" => id}, socket) do
    if Identity.can?(socket.assigns.current_user, "roles.delete") do
      {:ok, role} = Roles.get_role(id)
      {:noreply, assign(socket, role_to_delete: role)}
    else
      {:noreply,
       socket
       |> put_flash(:error, gettext("You don't have permission to delete roles."))
       |> push_patch(to: ~p"/admin/roles")}
    end
  end

  def handle_event("cancel_delete", _, socket) do
    {:noreply, assign(socket, role_to_delete: nil)}
  end

  def handle_event("confirm_delete", _, %{assigns: %{role_to_delete: role}} = socket) do
    case Roles.delete_role(role) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Role deleted successfully"))
         |> stream_delete(:roles, role)
         |> assign(role_to_delete: nil)
         |> push_patch(to: ~p"/admin/roles")}

      {:error, :role_in_use} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Cannot delete role because it is assigned to users"))
         |> assign(role_to_delete: nil)}
    end
  end

  @doc """
  Handles messages from child components, such as a successfully saved role.
  """
  @spec handle_info(term(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  @impl true
  def handle_info({RoleFormComponent, {:saved, role}}, socket) do
    {:noreply, stream_insert(socket, :roles, role)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex justify-between items-center">
        <div>
          <h1 class="text-2xl font-display font-bold text-base-content">
            {gettext("Roles & Policies")}
          </h1>
          <p class="text-base-content/60">
            {gettext("Manage system roles, permissions, and access policies.")}
          </p>
        </div>
        <.button
          :if={Identity.can?(@current_user, "roles.create")}
          patch={~p"/admin/roles/new"}
          class="btn btn-primary"
        >
          <.icon name="hero-plus" class="size-5" />
          {gettext("Create Role")}
        </.button>
      </div>

      <div class="flex gap-4">
        <.form for={nil} phx-change="search" phx-submit="search" class="w-full max-w-sm">
          <div class="relative">
            <.icon
              name="hero-magnifying-glass"
              class="absolute left-3 top-3.5 size-5 text-base-content/50 pointer-events-none z-10"
            />
            <.input
              type="text"
              name="search"
              value={@search}
              placeholder={gettext("Search roles...")}
              class="input input-bordered w-full pl-10"
              phx-debounce="500"
            />
          </div>
        </.form>
      </div>

      <.table id="roles" rows={@streams.roles}>
        <:col :let={{_id, role}} label="ID">
          <span class="font-mono text-xs opacity-50">{String.slice(role.id, 0..7)}</span>
        </:col>
        <:col :let={{_id, role}} label={gettext("Name")}>
          <span class="font-bold">{role.name}</span>
        </:col>
        <:col :let={{_id, role}} label={gettext("Access Level")}>
          <div class="flex gap-2">
            <span :if={"admin" in role.permissions} class="badge badge-error badge-soft font-bold">
              {gettext("Super Admin")}
            </span>
            <span
              :if={"admin" not in role.permissions}
              class="badge badge-primary badge-soft font-bold"
            >
              {gettext("%{count} permissions", count: length(role.permissions))}
            </span>
          </div>
        </:col>
        <:col :let={{_id, role}} label={gettext("Created At")}>
          <span class="text-sm opacity-60">{Calendar.strftime(role.inserted_at, "%d.%m.%Y")}</span>
        </:col>
        <:action :let={{_id, role}}>
          <div class="flex justify-end gap-2">
            <.button
              :if={Identity.can?(@current_user, "roles.update")}
              patch={~p"/admin/roles/#{role.id}/edit"}
              class="btn btn-ghost btn-xs btn-square"
            >
              <.icon name="hero-pencil-square" class="size-4" />
            </.button>
            <.button
              :if={Identity.can?(@current_user, "roles.delete")}
              type="button"
              phx-click="delete_click"
              phx-value-id={role.id}
              class="btn btn-ghost btn-xs btn-square text-error hover:bg-error/10"
            >
              <.icon name="hero-trash" class="size-4" />
            </.button>
          </div>
        </:action>
      </.table>

      <div class="flex justify-end">
        <.pagination
          meta={@meta}
          path_fn={
            fn page ->
              params =
                %{
                  "search" => @search,
                  "page" => page,
                  "page_size" => @meta.page_size,
                  "order_by" => @meta.flop.order_by,
                  "order_directions" => @meta.flop.order_directions
                }
                |> Enum.reject(fn {_, v} -> v in [nil, "", []] end)
                |> Map.new()

              ~p"/admin/roles?#{params}"
            end
          }
        />
      </div>

      <.slide_over
        id="role-slideover"
        show={@live_action in [:new, :edit]}
        title={@page_title}
        on_close={JS.patch(~p"/admin/roles")}
      >
        <.live_component
          :if={@role}
          module={RoleFormComponent}
          id={@role.id || :new}
          action={@live_action}
          role={@role}
          patch={~p"/admin/roles"}
        />
      </.slide_over>

      <.modal
        id="delete-modal"
        show={@role_to_delete != nil}
        title={gettext("Delete Role")}
        description={
          gettext("Are you sure you want to delete this role? This action cannot be undone.")
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
