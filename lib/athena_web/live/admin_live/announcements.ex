defmodule AthenaWeb.AdminLive.Announcements do
  @moduledoc """
  LiveView for managing announcements.

  Displays a paginated and searchable list of announcements using Streams.
  An "admin"-bypass account sees every announcement; any other account
  holding `announcements.read` sees only global announcements plus
  announcements for cohorts they instruct (enforced in
  `Athena.Announcements.list_for_admin/2`, not re-derived here). Handles
  deletion and integrates with `AnnouncementFormComponent` for creating
  and editing announcements via a slide-over.
  """
  use AthenaWeb, :live_view

  alias Athena.{Announcements, Identity, Learning}
  alias Athena.Announcements.Announcement
  alias AthenaWeb.AdminLive.AnnouncementFormComponent

  on_mount {AthenaWeb.Hooks.Permission, "announcements.read"}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(announcement_to_delete: nil)
     |> stream(:announcements, [])}
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

    case Announcements.list_for_admin(socket.assigns.current_user, flop_params) do
      {:ok, {announcements, meta}} ->
        owners =
          announcements |> Enum.map(& &1.author_id) |> Enum.uniq() |> Identity.get_accounts_map()

        cohorts =
          announcements
          |> Enum.map(& &1.cohort_id)
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()
          |> Learning.get_cohorts_map()

        socket =
          socket
          |> assign(meta: meta, search: search, owners: owners, cohorts: cohorts)
          |> stream(:announcements, announcements, reset: true)
          |> apply_action(socket.assigns.live_action, params)

        {:noreply, socket}

      {:error, _meta} ->
        {:noreply, push_patch(socket, to: ~p"/admin/announcements")}
    end
  end

  defp apply_action(socket, :index, _params) do
    assign(socket, page_title: gettext("Announcements"), announcement: nil)
  end

  defp apply_action(socket, :new, _params) do
    if Identity.can?(socket.assigns.current_user, "announcements.create") do
      assign(socket, page_title: gettext("Create Announcement"), announcement: %Announcement{})
    else
      socket
      |> put_flash(:error, gettext("You don't have permission to create announcements."))
      |> push_patch(to: ~p"/admin/announcements")
    end
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    current_user = socket.assigns.current_user

    case Announcements.get_announcement(id) do
      %Announcement{} = announcement ->
        if Identity.can?(current_user, "announcements.update") and
             Announcements.can_manage?(current_user, announcement) do
          assign(socket, page_title: gettext("Edit Announcement"), announcement: announcement)
        else
          socket
          |> put_flash(:error, gettext("You don't have permission to edit this announcement."))
          |> push_patch(to: ~p"/admin/announcements")
        end

      nil ->
        push_patch(socket, to: ~p"/admin/announcements")
    end
  end

  @impl true
  def handle_event("search", %{"search" => search}, socket) do
    params = build_query_params(socket.assigns, %{"search" => search, "page" => 1})
    {:noreply, push_patch(socket, to: ~p"/admin/announcements?#{params}")}
  end

  def handle_event("update_page_size", %{"page_size" => size}, socket) do
    params = build_query_params(socket.assigns, %{"page_size" => size, "page" => 1})
    {:noreply, push_patch(socket, to: ~p"/admin/announcements?#{params}")}
  end

  def handle_event("delete_click", %{"id" => id}, socket) do
    current_user = socket.assigns.current_user

    case Announcements.get_announcement(id) do
      %Announcement{} = announcement ->
        if Identity.can?(current_user, "announcements.delete") and
             Announcements.can_manage?(current_user, announcement) do
          {:noreply, assign(socket, announcement_to_delete: announcement)}
        else
          {:noreply,
           socket
           |> put_flash(:error, gettext("You don't have permission to delete this announcement."))}
        end

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, announcement_to_delete: nil)}
  end

  def handle_event(
        "confirm_delete",
        _params,
        %{assigns: %{announcement_to_delete: nil}} = socket
      ) do
    {:noreply, socket}
  end

  def handle_event(
        "confirm_delete",
        _params,
        %{assigns: %{announcement_to_delete: announcement}} = socket
      ) do
    case Announcements.delete_announcement(socket.assigns.current_user, announcement) do
      {:ok, _announcement} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Announcement deleted successfully"))
         |> stream_delete(:announcements, announcement)
         |> assign(announcement_to_delete: nil)}

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Failed to delete announcement"))
         |> assign(announcement_to_delete: nil)}
    end
  end

  @impl true
  def handle_info({AnnouncementFormComponent, {:saved, announcement}}, socket) do
    {:noreply, stream_insert(socket, :announcements, announcement)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.page_container size="wide" class="space-y-6">
      <div class="flex justify-between items-center">
        <div>
          <h1 class="text-2xl font-display font-bold text-base-content">
            {gettext("Announcements")}
          </h1>
          <p class="text-base-content/60">{gettext("Manage global and cohort announcements.")}</p>
        </div>
        <.button
          :if={Identity.can?(@current_user, "announcements.create")}
          patch={~p"/admin/announcements/new?#{build_query_params(assigns, %{})}"}
          class="btn btn-primary"
        >
          <.icon name="hero-plus" class="size-5" />
          {gettext("Create Announcement")}
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
              placeholder={gettext("Search announcements...")}
              class="input input-bordered w-full pl-10"
              phx-debounce="500"
            />
          </div>
        </.form>
      </div>

      <% path_fn = fn overrides ->
        ~p"/admin/announcements?#{build_query_params(assigns, overrides)}"
      end %>

      <.table id="announcements" rows={@streams.announcements} meta={@meta} path_fn={path_fn}>
        <:col :let={{_id, a}} label={gettext("Title")} sort="title">
          <span class="font-bold">{a.title}</span>
        </:col>
        <:col :let={{_id, a}} label={gettext("Audience")}>
          <.badge tone={if a.scope == :global, do: "primary", else: "neutral"}>
            {if a.scope == :global,
              do: gettext("Global"),
              else: Map.get(@cohorts, a.cohort_id) |> cohort_name()}
          </.badge>
        </:col>
        <:col :let={{_id, a}} label={gettext("Author")}>
          {owner_name(@owners, a.author_id)}
        </:col>
        <:col :let={{_id, a}} label={gettext("Created At")} sort="inserted_at">
          <span class="text-sm opacity-60">{Calendar.strftime(a.inserted_at, "%d.%m.%Y")}</span>
        </:col>
        <:action :let={{_id, a}}>
          <div class="flex justify-end gap-2">
            <.icon_button
              :if={Identity.can?(@current_user, "announcements.update")}
              patch={~p"/admin/announcements/#{a.id}/edit?#{build_query_params(assigns, %{})}"}
              icon="hero-pencil-square"
              label={gettext("Edit")}
            />
            <.icon_button
              :if={Identity.can?(@current_user, "announcements.delete")}
              type="button"
              phx-click="delete_click"
              phx-value-id={a.id}
              icon="hero-trash"
              label={gettext("Delete")}
              variant="danger"
            />
          </div>
        </:action>
      </.table>

      <.empty_state
        :if={@meta.total_count == 0}
        icon="hero-megaphone"
        title={gettext("No announcements yet")}
        description={gettext("Create one to get started.")}
      />

      <div class="flex justify-end">
        <.pagination meta={@meta} path_fn={path_fn} />
      </div>

      <.slide_over
        id="announcement-slideover"
        show={@live_action in [:new, :edit]}
        title={@page_title}
        on_close={JS.patch(~p"/admin/announcements?#{build_query_params(assigns, %{})}")}
      >
        <.live_component
          :if={@announcement}
          module={AnnouncementFormComponent}
          id={@announcement.id || :new}
          action={@live_action}
          announcement={@announcement}
          current_user={@current_user}
          patch={~p"/admin/announcements?#{build_query_params(assigns, %{})}"}
        />
      </.slide_over>

      <.modal
        id="delete-announcement-modal"
        show={@announcement_to_delete != nil}
        title={gettext("Delete Announcement")}
        description={
          gettext("Are you sure you want to delete this announcement? This action cannot be undone.")
        }
        confirm_label={gettext("Delete")}
        danger={true}
        on_cancel={JS.push("cancel_delete")}
        on_confirm={JS.push("confirm_delete")}
      />
    </.page_container>
    """
  end

  defp owner_name(owners, author_id) do
    case Map.get(owners, author_id) do
      nil -> "—"
      account -> Identity.display_name(account)
    end
  end

  defp cohort_name(nil), do: "—"
  defp cohort_name(cohort), do: cohort.name

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
end
