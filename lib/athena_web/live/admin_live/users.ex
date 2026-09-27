defmodule AthenaWeb.AdminLive.Users do
  @moduledoc """
  LiveView for managing system user accounts and profiles.

  Displays a paginated, sortable, searchable list of users using Streams for
  optimal DOM diffing - search matches login or profile name (ФИО), and can
  be narrowed to one cohort's members. Handles account soft-deletion and
  integrates with `UserFormComponent` for creating and editing users via a
  slide-over.
  """
  use AthenaWeb, :live_view

  alias Athena.{Identity, Learning, Repo}
  alias Athena.Identity.{Account, Profile}
  alias AthenaWeb.AdminLive.UserFormComponent

  on_mount {AthenaWeb.Hooks.Permission, "users.read"}

  @doc """
  Initializes the LiveView, setting up the accounts stream and default assigns.
  """
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    # The cohort filter is only worth offering to someone who can actually
    # see cohorts - a "users.read" admin without "cohorts.read" would
    # otherwise get a permanently empty dropdown.
    cohort_options =
      if Identity.can?(user, "cohorts.read"), do: Learning.get_cohort_options(user), else: []

    {:ok,
     socket
     |> assign(account_to_delete: nil)
     |> assign(cohort_options: cohort_options)
     |> stream(:accounts, [])}
  end

  @doc """
  Handles URL parameters for pagination, sorting, search, cohort filtering,
  and live actions (:index, :new, :edit).
  """
  @spec handle_params(map(), String.t(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  @impl true
  def handle_params(params, _url, socket) do
    search = Map.get(params, "search", "")
    cohort_id = Map.get(params, "cohort_id", "")

    flop_params = Map.put(params, "filters", build_flop_filters(search, cohort_id))

    case Identity.list_accounts(socket.assigns.current_user, flop_params,
           preload: [:profile, :role]
         ) do
      {:ok, {accounts, meta}} ->
        socket =
          socket
          |> assign(meta: meta, search: search, cohort_id: cohort_id)
          |> stream(:accounts, accounts, reset: true)
          |> apply_action(socket.assigns.live_action, params)

        {:noreply, socket}

      {:error, _meta} ->
        {:noreply, push_patch(socket, to: ~p"/admin/users")}
    end
  end

  # Both `search` and `cohort_id` resolve to a set of matching account ids
  # first (login/name search can't be expressed as a single Flop filter -
  # it has to match across two schemas, OR'd together), then feed an `:in`
  # filter on `id` - the same pattern the grading screen's "Student" filter
  # and cohort filter already use for submissions. Combined, the two
  # narrow down to their intersection, same as any other pair of filters.
  defp build_flop_filters(search, cohort_id) do
    filters = []

    filters =
      if search != "",
        do: [id_in_filter(Identity.get_account_ids_by_login_or_name(search)) | filters],
        else: filters

    filters =
      if cohort_id != "",
        do: [id_in_filter(Identity.get_account_ids_by_cohort(cohort_id)) | filters],
        else: filters

    filters
    |> Enum.with_index(fn filter, index -> {Integer.to_string(index), filter} end)
    |> Map.new()
  end

  # An empty match list would make `id in []` - Ecto/Postgres treats that as
  # always-false already, but staying explicit here (a made-up id no account
  # can ever have) keeps the intent obvious rather than relying on that.
  defp id_in_filter([]), do: %{"field" => "id", "op" => "in", "value" => [Ecto.UUID.generate()]}
  defp id_in_filter(ids), do: %{"field" => "id", "op" => "in", "value" => ids}

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
  Handles UI events such as filtering and user deletion confirmations.
  """
  @impl true
  def handle_event("update_filters", params, socket) do
    overrides = %{
      "search" => params["search"] || "",
      "cohort_id" => params["cohort_id"] || "",
      "page" => 1
    }

    query_params = build_query_params(socket.assigns, overrides)
    {:noreply, push_patch(socket, to: ~p"/admin/users?#{query_params}")}
  end

  def handle_event("clear_cache", _params, socket) do
    if Identity.can?(socket.assigns.current_user, "users.delete") do
      Identity.clear_cache()
      |> case do
        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(:info, gettext("Account cache cleared successfully"))}

        {:error, _} ->
          {:noreply,
           socket
           |> put_flash(:error, gettext("Failed to clear account cache"))}
      end
    else
      {:noreply,
       socket
       |> put_flash(:error, gettext("You don't have permission to clear users cache."))
       |> push_patch(to: ~p"/admin/users")}
    end
  end

  def handle_event("update_page_size", %{"page_size" => size}, socket) do
    params = build_query_params(socket.assigns, %{"page_size" => size, "page" => 1})
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
    <.page_container size="wide" class="space-y-6">
      <div class="flex justify-between items-center">
        <div>
          <h1 class="text-2xl font-display font-bold text-base-content">{gettext("Users")}</h1>
          <p class="text-base-content/60">{gettext("Manage system accounts and user profiles.")}</p>
        </div>
        <div class="flex gap-2">
          <.button
            :if={Identity.can?(@current_user, "system.cache")}
            type="button"
            variant="warning"
            phx-click="clear_cache"
          >
            <.icon name="hero-arrow-path" class="size-5" />
            {gettext("Clear Cache")}
          </.button>
          <.button
            :if={Identity.can?(@current_user, "users.create")}
            patch={~p"/admin/users/new?#{build_query_params(assigns, %{})}"}
            class="btn btn-primary"
          >
            <.icon name="hero-plus" class="size-5" />
            {gettext("Create User")}
          </.button>
        </div>
      </div>

      <.form
        for={nil}
        phx-change="update_filters"
        phx-submit="update_filters"
        class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4"
      >
        <div class="relative">
          <.icon
            name="hero-magnifying-glass"
            class="absolute left-3 top-3.5 size-5 text-base-content/50 z-10"
          />
          <.input
            type="text"
            name="search"
            value={@search}
            placeholder={gettext("Search by login or name...")}
            class="input input-bordered w-full pl-10"
            phx-debounce="500"
          />
        </div>

        <.input
          :if={@cohort_options != []}
          type="select"
          name="cohort_id"
          value={@cohort_id}
          options={@cohort_options}
          prompt={gettext("All Cohorts")}
        />
      </.form>

      <% path_fn = fn overrides -> ~p"/admin/users?#{build_query_params(assigns, overrides)}" end %>

      <.table id="users" rows={@streams.accounts} meta={@meta} path_fn={path_fn}>
        <:col :let={{_id, acc}} label="ID">
          <span class="font-mono text-xs opacity-50">{String.slice(acc.id, 0..7)}</span>
        </:col>
        <:col :let={{_id, acc}} label={gettext("Login")} sort="login">
          <span class="font-bold">{acc.login}</span>
        </:col>
        <:col :let={{_id, acc}} label={gettext("Full Name")}>
          {if acc.profile, do: Profile.full_name(acc.profile), else: "—"}
        </:col>
        <:col :let={{_id, acc}} label={gettext("Status")} sort="status">
          <.badge tone={account_status_tone(acc.status)}>
            {Atom.to_string(acc.status) |> String.replace("_", " ") |> String.capitalize()}
          </.badge>
        </:col>
        <:col :let={{_id, acc}} label={gettext("Role")}>
          <div class="badge badge-outline">{acc.role.name}</div>
        </:col>
        <:col :let={{_id, acc}} label={gettext("Created At")} sort="inserted_at">
          <span class="text-sm opacity-60">{TimeZones.format(acc.inserted_at, "%d.%m.%Y")}</span>
        </:col>
        <:action :let={{_id, acc}}>
          <div class="flex justify-end gap-2">
            <.icon_button
              :if={Identity.can?(@current_user, "users.update")}
              patch={~p"/admin/users/#{acc.id}/edit?#{build_query_params(assigns, %{})}"}
              icon="hero-pencil-square"
              label={gettext("Edit")}
            />
            <.icon_button
              :if={Identity.can?(@current_user, "users.delete")}
              type="button"
              phx-click="delete_click"
              phx-value-id={acc.id}
              icon="hero-trash"
              label={gettext("Delete")}
              variant="danger"
            />
          </div>
        </:action>
      </.table>

      <.empty_state
        :if={@meta.total_count == 0}
        icon="hero-users"
        title={gettext("No users yet")}
        description={gettext("Create one to get started.")}
      />

      <div class="flex justify-end">
        <.pagination meta={@meta} path_fn={path_fn} />
      </div>

      <.slide_over
        id="account-slideover"
        show={@live_action in [:new, :edit]}
        title={@page_title}
        on_close={JS.patch(~p"/admin/users?#{build_query_params(assigns, %{})}")}
      >
        <.live_component
          :if={@account}
          module={UserFormComponent}
          id={@account.id || :new}
          action={@live_action}
          account={@account}
          current_user={@current_user}
          patch={~p"/admin/users?#{build_query_params(assigns, %{})}"}
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
    </.page_container>
    """
  end

  defp account_status_tone(:active), do: "success"
  defp account_status_tone(:blocked), do: "error"
  defp account_status_tone(:temporary_blocked), do: "warning"

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
      "cohort_id" => assigns.cohort_id,
      "page" => meta.current_page,
      "page_size" => meta.page_size,
      "order_by" => order_by,
      "order_directions" => order_directions
    }
    |> Map.merge(overrides)
    |> Enum.reject(fn {_, v} -> is_nil(v) or v == "" or v == [] end)
    |> Map.new()
  end
end
