defmodule AthenaWeb.AdminLive.Roles do
  use AthenaWeb, :live_view

  alias Athena.Identity.Roles
  alias Athena.Identity.Role
  alias AthenaWeb.AdminLive.RoleFormComponent

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, role_to_delete: nil)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    case Roles.list_roles(params) do
      {:ok, {roles, meta}} ->
        socket =
          socket
          |> assign(roles: roles, meta: meta, search: params["search"] || "")
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
    assign(socket, page_title: gettext("Create Role"), role: %Role{})
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    case Roles.get_role(id) do
      {:ok, role} -> assign(socket, page_title: gettext("Edit Role"), role: role)
      _ -> push_patch(socket, to: ~p"/admin/roles")
    end
  end

  @impl true
  def handle_event("search", %{"search" => search}, socket) do
    flop = %{
      socket.assigns.meta.flop
      | filters: [%{field: :name, op: :ilike_and, value: search}],
        page: 1
    }

    params =
      flop
      |> Map.from_struct()
      |> Enum.reject(fn {_, v} -> is_nil(v) or v == [] end)
      |> Map.new()

    {:noreply, push_patch(socket, to: ~p"/admin/roles?#{params}")}
  end

  def handle_event("delete_click", %{"id" => id}, socket) do
    {:ok, role} = Roles.get_role(id)
    {:noreply, assign(socket, role_to_delete: role)}
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
         |> assign(role_to_delete: nil)
         |> push_patch(to: ~p"/admin/roles")}

      {:error, :role_in_use} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Cannot delete role because it is assigned to users"))
         |> assign(role_to_delete: nil)}
    end
  end

  @impl true
  def handle_info({RoleFormComponent, {:saved, _role}}, socket) do
    {:noreply, socket}
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
        <.link patch={~p"/admin/roles/new"} class="btn btn-primary">
          <.icon name="hero-plus" class="size-5" />
          {gettext("Create Role")}
        </.link>
      </div>

      <div class="flex gap-4">
        <form phx-change="search" class="w-full max-w-sm relative">
          <.icon
            name="hero-magnifying-glass"
            class="absolute left-3 top-1/2 -translate-y-1/2 size-5 text-base-content/50"
          />
          <input
            type="text"
            name="search"
            value={@search}
            placeholder={gettext("Search roles...")}
            class="input input-bordered w-full pl-10"
          />
        </form>
      </div>

      <div class="border border-base-300 rounded-xl overflow-hidden bg-base-100 shadow-sm">
        <.table id="roles" rows={@roles}>
          <:col :let={role} label="ID">
            <span class="font-mono text-xs opacity-50">{String.slice(role.id, 0..7)}</span>
          </:col>
          <:col :let={role} label={gettext("Name")}><span class="font-bold">{role.name}</span></:col>
          <:col :let={role} label={gettext("Access Level")}>
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
          <:col :let={role} label={gettext("Created At")}>
            <span class="text-sm opacity-60">{Calendar.strftime(role.inserted_at, "%d.%m.%Y")}</span>
          </:col>
          <:action :let={role}>
            <div class="flex justify-end gap-2">
              <.link patch={~p"/admin/roles/#{role.id}/edit"} class="btn btn-ghost btn-xs btn-square">
                <.icon name="hero-pencil-square" class="size-4" />
              </.link>
              <button
                type="button"
                phx-click="delete_click"
                phx-value-id={role.id}
                class="btn btn-ghost btn-xs btn-square text-error hover:bg-error/10"
              >
                <.icon name="hero-trash" class="size-4" />
              </button>
            </div>
          </:action>
        </.table>
      </div>

      <div class="flex justify-end">
        <.pagination
          meta={@meta}
          path_fn={
            fn page ->
              params =
                Map.from_struct(%{@meta.flop | page: page})
                |> Enum.reject(fn {_, v} -> is_nil(v) or v == [] end)
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
