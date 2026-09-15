defmodule AthenaWeb.AdminLive.Announcements do
  @moduledoc """
  LiveView for managing announcements.

  Displays a paginated and searchable list of announcements using Streams.
  An "admin"-bypass account sees every announcement; any other account
  holding `announcements.read` sees only global announcements plus
  announcements for cohorts they instruct (enforced in
  `Athena.Announcements.list_for_admin/2`, not re-derived here). Create/edit
  is a full standalone page (`AnnouncementForm`, not a slide-over — TipTap
  needs the room); this LiveView only lists and deletes.
  """
  use AthenaWeb, :live_view

  alias Athena.{Announcements, Identity, Learning}

  on_mount {AthenaWeb.Hooks.Permission, "announcements.read"}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: gettext("Announcements"), announcement_to_delete: nil)
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

        {:noreply,
         socket
         |> assign(meta: meta, search: search, owners: owners, cohorts: cohorts)
         |> stream(:announcements, announcements, reset: true)}

      {:error, _meta} ->
        {:noreply, push_patch(socket, to: ~p"/admin/announcements")}
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
      %Announcements.Announcement{} = announcement ->
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
         |> put_flash(:success, gettext("Announcement deleted successfully"))
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
          navigate={~p"/admin/announcements/new"}
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
          <div class="flex items-center gap-2">
            <.icon
              :if={a.important}
              name="hero-exclamation-triangle-solid"
              class="size-4 text-warning shrink-0"
            />
            <span class="font-bold">{a.title}</span>
          </div>
        </:col>
        <:col :let={{_id, a}} label={gettext("Audience")}>
          <.badge tone={if a.scope == :global, do: "primary", else: "info"}>
            {audience_label(a, @cohorts)}
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
              navigate={~p"/admin/announcements/#{a.id}/edit"}
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

  defp audience_label(%{scope: :global}, _cohorts), do: gettext("Global")

  defp audience_label(%{scope: :cohort, cohort_id: cohort_id}, cohorts) do
    case Map.get(cohorts, cohort_id) do
      nil -> "—"
      %{name: name, type: :team} -> "#{gettext("Team")}: #{name}"
      %{name: name} -> "#{gettext("Cohort")}: #{name}"
    end
  end

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
