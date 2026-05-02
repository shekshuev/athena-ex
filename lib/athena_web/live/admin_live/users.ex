defmodule AthenaWeb.AdminLive.Users do
  @moduledoc """
  LiveView for managing system user accounts and profiles.

  Displays a paginated and searchable list of users using Streams for optimal
  DOM diffing. Handles account soft-deletion and integrates with `UserFormComponent`
  for creating and editing users via a slide-over.
  """
  use AthenaWeb, :live_view

  alias Athena.{Identity, Repo}
  alias Athena.Identity.{Account, Profile}
  alias AthenaWeb.AdminLive.UserFormComponent

  on_mount {AthenaWeb.Hooks.Permission, "users.read"}

  @doc """
  Initializes the LiveView, setting up the accounts stream and default assigns.
  """
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(account_to_delete: nil)
     |> stream(:accounts, [])}
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
          "0" => %{"field" => "login", "op" => "ilike_and", "value" => search}
        })
      else
        params
      end

    case Identity.list_accounts(socket.assigns.current_user, flop_params,
           preload: [:profile, :role]
         ) do
      {:ok, {accounts, meta}} ->
        socket =
          socket
          |> assign(meta: meta, search: search)
          |> stream(:accounts, accounts, reset: true)
          |> apply_action(socket.assigns.live_action, params)

        {:noreply, socket}

      {:error, _meta} ->
        {:noreply, push_patch(socket, to: ~p"/admin/users")}
    end
  end

  defp apply_action(socket, :index, _params) do
    assign(socket, page_title: gettext("Users"), account: nil)
  end

  defp apply_action(socket, :new, _params) do
    if Identity.can?(socket.assigns.current_user, "users.create") do
      assign(socket, page_title: gettext("Create User"), account: %Account{})
    else
      socket
      |> put_flash(:error, gettext("You don't have permission to create users."))
      |> push_patch(to: ~p"/admin/users")
    end
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    if Identity.can?(socket.assigns.current_user, "users.update") do
      case Identity.get_account(id) do
        {:ok, account} -> assign(socket, page_title: gettext("Edit User"), account: account)
        _ -> push_patch(socket, to: ~p"/admin/users")
      end
    else
      socket
      |> put_flash(:error, gettext("You don't have permission to edit users."))
      |> push_patch(to: ~p"/admin/users")
    end
  end

  @doc """
  Handles UI events such as searching and user deletion confirmations.
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

    {:noreply, push_patch(socket, to: ~p"/admin/users?#{params}")}
  end

  def handle_event("delete_click", %{"id" => id}, socket) do
    if Identity.can?(socket.assigns.current_user, "users.delete") do
      {:ok, account} = Identity.get_account(id)
      {:noreply, assign(socket, account_to_delete: account)}
    else
      {:noreply,
       socket
       |> put_flash(:error, gettext("You don't have permission to delete users."))
       |> push_patch(to: ~p"/admin/users")}
    end
  end

  def handle_event("confirm_delete", _, %{assigns: %{account_to_delete: account}} = socket) do
    case Identity.soft_delete_account(account) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Account deleted successfully"))
         |> stream_delete(:accounts, account)
         |> assign(account_to_delete: nil)}

      {:error, _} ->
        {:noreply, socket |> put_flash(:error, gettext("Failed to delete account"))}
    end
  end

  def handle_event("cancel_delete", _, socket) do
    {:noreply, assign(socket, account_to_delete: nil)}
  end

  @doc """
  Handles messages from child components, such as a successfully saved user.
  """
  @spec handle_info(term(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  @impl true
  def handle_info({UserFormComponent, {:saved, account}}, socket) do
    account = Repo.preload(account, [:profile, :role])
    {:noreply, stream_insert(socket, :accounts, account)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex justify-between items-center">
        <div>
          <h1 class="text-2xl font-display font-bold text-base-content">{gettext("Users")}</h1>
          <p class="text-base-content/60">{gettext("Manage system accounts and user profiles.")}</p>
        </div>
        <.button
          :if={Identity.can?(@current_user, "users.create")}
          patch={~p"/admin/users/new"}
          class="btn btn-primary"
        >
          <.icon name="hero-plus" class="size-5" />
          {gettext("Create User")}
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
              placeholder={gettext("Search users...")}
              class="input input-bordered w-full pl-10"
              phx-debounce="500"
            />
          </div>
        </.form>
      </div>

      <.table id="users" rows={@streams.accounts}>
        <:col :let={{_id, acc}} label="ID">
          <span class="font-mono text-xs opacity-50">{String.slice(acc.id, 0..7)}</span>
        </:col>
        <:col :let={{_id, acc}} label={gettext("Login")}>
          <span class="font-bold">{acc.login}</span>
        </:col>
        <:col :let={{_id, acc}} label={gettext("Full Name")}>
          {if acc.profile, do: Profile.full_name(acc.profile), else: "—"}
        </:col>
        <:col :let={{_id, acc}} label={gettext("Status")}>
          <.status_badge status={acc.status} />
        </:col>
        <:col :let={{_id, acc}} label={gettext("Role")}>
          <div class="badge badge-outline">{acc.role.name}</div>
        </:col>
        <:col :let={{_id, acc}} label={gettext("Created At")}>
          <span class="text-sm opacity-60">{Calendar.strftime(acc.inserted_at, "%d.%m.%Y")}</span>
        </:col>
        <:action :let={{_id, acc}}>
          <div class="flex justify-end gap-2">
            <.button
              :if={Identity.can?(@current_user, "users.update")}
              patch={~p"/admin/users/#{acc.id}/edit"}
              class="btn btn-ghost btn-xs btn-square"
            >
              <.icon name="hero-pencil-square" class="size-4" />
            </.button>
            <.button
              :if={Identity.can?(@current_user, "users.delete")}
              type="button"
              phx-click="delete_click"
              phx-value-id={acc.id}
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
          path_fn={fn p -> ~p"/admin/users?#{%{"page" => p, "search" => @search}}" end}
        />
      </div>

      <.slide_over
        id="account-slideover"
        show={@live_action in [:new, :edit]}
        title={@page_title}
        on_close={JS.patch(~p"/admin/users")}
      >
        <.live_component
          :if={@account}
          module={UserFormComponent}
          id={@account.id || :new}
          action={@live_action}
          account={@account}
          current_user={@current_user}
          patch={~p"/admin/users"}
        />
      </.slide_over>

      <.modal
        id="delete-user-modal"
        show={@account_to_delete != nil}
        title={gettext("Delete User")}
        description={
          gettext(
            "Are you sure you want to delete this account? This will also block profile access."
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
      @status == :active && "badge-success badge-soft",
      @status == :blocked && "badge-error badge-soft",
      @status == :temporary_blocked && "badge-warning badge-soft"
    ]}>
      {Atom.to_string(@status) |> String.replace("_", " ") |> String.capitalize()}
    </span>
    """
  end
end
