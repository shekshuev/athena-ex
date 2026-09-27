defmodule AthenaWeb.AdminLive.Files do
  @moduledoc """
  LiveView for admin-wide file management and storage-quota monitoring.

  Displays a paginated, searchable, filterable, sortable table over every
  file in the system (regardless of owner), plus a per-role storage-quota
  panel. Access is gated by the `files.*` permissions, unlike
  `AthenaWeb.FileLive.Index` which is open to every authenticated account
  for their own files.
  """
  use AthenaWeb, :live_view

  alias Athena.{Identity, Media}

  on_mount {AthenaWeb.Hooks.Permission, "files.read"}

  @contexts ~w(personal avatar course_material submission)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(file_to_delete: nil, role_to_edit_quota: nil)
     |> assign_role_quotas()
     |> stream(:files, [])}
  end

  @impl true
  def handle_params(params, _url, socket) do
    search = Map.get(params, "search", "")
    context = Map.get(params, "context", "")

    flop_params = build_flop_filters(params, search, context)

    case Media.list_files(socket.assigns.current_user, flop_params) do
      {:ok, {files, meta}} ->
        owners =
          files
          |> Enum.map(& &1.owner_id)
          |> Enum.uniq()
          |> Identity.get_accounts_map()

        {:noreply,
         socket
         |> assign(meta: meta, search: search, context_filter: context, owners: owners)
         |> stream(:files, files, reset: true)}

      {:error, _meta} ->
        {:noreply, push_patch(socket, to: ~p"/admin/files")}
    end
  end

  defp build_flop_filters(params, search, context) do
    filters =
      %{}
      |> maybe_put_filter("0", "original_name", "ilike_and", search)
      |> maybe_put_filter("1", "context", "==", context)

    if filters == %{}, do: params, else: Map.put(params, "filters", filters)
  end

  defp maybe_put_filter(filters, _index, _field, _op, ""), do: filters

  defp maybe_put_filter(filters, index, field, op, value) do
    Map.put(filters, index, %{"field" => field, "op" => op, "value" => value})
  end

  defp assign_role_quotas(socket) do
    assign(socket, role_quotas: Media.list_role_quotas(socket.assigns.current_user))
  end

  @impl true
  def handle_event("search", %{"search" => search}, socket) do
    params = build_query_params(socket.assigns, %{"search" => search, "page" => 1})
    {:noreply, push_patch(socket, to: ~p"/admin/files?#{params}")}
  end

  def handle_event("filter_context", %{"context" => context}, socket) do
    params = build_query_params(socket.assigns, %{"context" => context, "page" => 1})
    {:noreply, push_patch(socket, to: ~p"/admin/files?#{params}")}
  end

  def handle_event("update_page_size", %{"page_size" => size}, socket) do
    params = build_query_params(socket.assigns, %{"page_size" => size, "page" => 1})
    {:noreply, push_patch(socket, to: ~p"/admin/files?#{params}")}
  end

  def handle_event("delete_click", %{"id" => id}, socket) do
    if Identity.can?(socket.assigns.current_user, "files.delete") do
      {:noreply, assign(socket, file_to_delete: Media.get_file(id))}
    else
      {:noreply,
       socket
       |> put_flash(:error, gettext("You don't have permission to delete files."))
       |> push_patch(to: ~p"/admin/files")}
    end
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, file_to_delete: nil)}
  end

  def handle_event("confirm_delete", _params, %{assigns: %{file_to_delete: nil}} = socket) do
    {:noreply, socket}
  end

  def handle_event(
        "confirm_delete",
        _params,
        %{assigns: %{file_to_delete: file}} = socket
      ) do
    case Media.delete_file(file) do
      {:ok, _file} ->
        socket =
          socket
          |> put_flash(:info, gettext("File deleted successfully"))
          |> stream_delete(:files, file)
          |> assign(file_to_delete: nil)

        socket = if file.context == :personal, do: assign_role_quotas(socket), else: socket

        {:noreply, socket}

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Failed to delete file"))
         |> assign(file_to_delete: nil)}
    end
  end

  def handle_event("edit_quota_click", %{"role-id" => role_id}, socket) do
    if Identity.can?(socket.assigns.current_user, "files.update") do
      entry = Enum.find(socket.assigns.role_quotas, &(&1.role.id == role_id))
      {:noreply, assign(socket, role_to_edit_quota: entry)}
    else
      {:noreply,
       socket
       |> put_flash(:error, gettext("You don't have permission to edit storage quotas."))}
    end
  end

  def handle_event("cancel_quota_edit", _params, socket) do
    {:noreply, assign(socket, role_to_edit_quota: nil)}
  end

  def handle_event("save_quota", %{"limit_mb" => limit_mb}, socket) do
    if Identity.can?(socket.assigns.current_user, "files.update") do
      role = socket.assigns.role_to_edit_quota.role

      with {mb, _} <- Float.parse(limit_mb),
           {:ok, _quota} <- Media.set_quota(role.id, round(mb * 1024 * 1024)) do
        {:noreply,
         socket
         |> put_flash(:info, gettext("Storage quota updated successfully"))
         |> assign(role_to_edit_quota: nil)
         |> assign_role_quotas()}
      else
        _ ->
          {:noreply, put_flash(socket, :error, gettext("Failed to update storage quota"))}
      end
    else
      {:noreply,
       socket
       |> put_flash(:error, gettext("You don't have permission to edit storage quotas."))
       |> assign(role_to_edit_quota: nil)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.page_container size="wide" class="space-y-6">
      <div>
        <h1 class="text-2xl font-display font-bold text-base-content">{gettext("System Files")}</h1>
        <p class="text-base-content/60">{gettext("Global storage monitoring and quotas.")}</p>
      </div>

      <div class="bg-base-100 border border-base-300 rounded-lg p-4">
        <h2 class="font-bold text-lg mb-4">{gettext("Storage Quotas by Role")}</h2>
        <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
          <div
            :for={%{role: role, used: used, limit: limit} <- @role_quotas}
            class="border border-base-200 rounded-md p-3"
          >
            <div class="flex justify-between items-center mb-1">
              <span class="font-bold text-sm">{role.name}</span>
              <span class="text-xs text-base-content/60">
                {Media.format_bytes(used)} / {Media.format_bytes(limit)}
              </span>
            </div>
            <div class="w-full bg-base-300 rounded-sm h-2 overflow-hidden mb-2">
              <div
                class={["h-full", quota_tone(used, limit)]}
                style={"width: #{quota_pct(used, limit)}%"}
              >
              </div>
            </div>
            <.button
              :if={Identity.can?(@current_user, "files.update")}
              type="button"
              variant="ghost"
              size="xs"
              phx-click="edit_quota_click"
              phx-value-role-id={role.id}
            >
              {gettext("Edit limit")}
            </.button>
          </div>
        </div>
      </div>

      <div class="flex flex-col sm:flex-row gap-4">
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
              placeholder={gettext("Search files...")}
              class="input input-bordered w-full pl-10"
              phx-debounce="500"
            />
          </div>
        </.form>

        <.form for={nil} phx-change="filter_context">
          <.input
            type="select"
            name="context"
            value={@context_filter}
            prompt={gettext("All contexts")}
            options={Enum.map(contexts(), &{context_label(&1), &1})}
            class="select select-bordered"
          />
        </.form>
      </div>

      <% path_fn = fn overrides -> ~p"/admin/files?#{build_query_params(assigns, overrides)}" end %>

      <.table id="admin-files" rows={@streams.files} meta={@meta} path_fn={path_fn}>
        <:col :let={{_id, file}} label="ID">
          <span class="font-mono text-xs opacity-50">{String.slice(file.id, 0..7)}</span>
        </:col>
        <:col :let={{_id, file}} label={gettext("Name")} sort="original_name">
          <div class="flex items-center gap-2">
            <.file_type_icon mime_type={file.mime_type} class="size-4 text-base-content/50" />
            <span class="font-bold">{file.original_name}</span>
          </div>
        </:col>
        <:col :let={{_id, file}} label={gettext("Owner")}>
          {owner_name(@owners, file.owner_id)}
        </:col>
        <:col :let={{_id, file}} label={gettext("Context")}>
          <.badge tone="neutral">{context_label(to_string(file.context))}</.badge>
        </:col>
        <:col :let={{_id, file}} label={gettext("Type")}>
          <span class="text-xs opacity-60">{file.mime_type}</span>
        </:col>
        <:col :let={{_id, file}} label={gettext("Size")} sort="size">
          {Media.format_bytes(file.size)}
        </:col>
        <:col :let={{_id, file}} label={gettext("Uploaded At")} sort="inserted_at">
          <span class="text-sm opacity-60">{TimeZones.format(file.inserted_at, "%d.%m.%Y")}</span>
        </:col>
        <:action :let={{_id, file}}>
          <div class="flex justify-end gap-2">
            <.icon_button
              href={~p"/media/#{String.split(file.key, "/")}"}
              icon="hero-arrow-down-tray"
              label={gettext("Download")}
            />
            <.icon_button
              :if={Identity.can?(@current_user, "files.delete")}
              type="button"
              phx-click="delete_click"
              phx-value-id={file.id}
              icon="hero-trash"
              label={gettext("Delete")}
              variant="danger"
            />
          </div>
        </:action>
      </.table>

      <.empty_state
        :if={@meta.total_count == 0}
        icon="hero-server"
        title={gettext("No files")}
        description={gettext("No files match the current filters.")}
      />

      <div class="flex justify-end">
        <.pagination meta={@meta} path_fn={path_fn} />
      </div>

      <.modal
        id="quota-edit-modal"
        show={@role_to_edit_quota != nil}
        title={gettext("Edit Storage Quota")}
        on_cancel={JS.push("cancel_quota_edit")}
      >
        <.form :if={@role_to_edit_quota} for={nil} phx-submit="save_quota" class="space-y-4">
          <p class="text-sm text-base-content/70">
            {gettext("Role")}: <span class="font-bold">{@role_to_edit_quota.role.name}</span>
          </p>
          <.input
            type="number"
            name="limit_mb"
            label={gettext("Storage limit (MB)")}
            value={round(@role_to_edit_quota.limit / 1024 / 1024)}
            min="0"
            step="1"
            required
          />
          <div class="flex justify-end gap-3">
            <.button type="button" phx-click="cancel_quota_edit">{gettext("Cancel")}</.button>
            <.button type="submit" variant="primary">{gettext("Save")}</.button>
          </div>
        </.form>
      </.modal>

      <.modal
        id="delete-file-modal"
        show={@file_to_delete != nil}
        title={gettext("Delete File")}
        description={
          gettext("Are you sure you want to delete this file? This action cannot be undone.")
        }
        confirm_label={gettext("Delete")}
        danger={true}
        on_cancel={JS.push("cancel_delete")}
        on_confirm={JS.push("confirm_delete")}
      />
    </.page_container>
    """
  end

  defp owner_name(owners, owner_id) do
    case Map.get(owners, owner_id) do
      nil -> "—"
      account -> Identity.display_name(account)
    end
  end

  defp context_label("personal"), do: gettext("Personal")
  defp context_label("avatar"), do: gettext("Avatar")
  defp context_label("course_material"), do: gettext("Course Material")
  defp context_label("submission"), do: gettext("Submission")
  defp context_label(other), do: other

  defp quota_pct(_used, limit) when limit <= 0, do: 100
  defp quota_pct(used, limit), do: used |> Kernel./(limit) |> Kernel.*(100) |> min(100) |> round()

  defp quota_tone(used, limit) do
    case quota_pct(used, limit) do
      pct when pct >= 90 -> "bg-error"
      pct when pct >= 70 -> "bg-warning"
      _ -> "bg-primary"
    end
  end

  @doc false
  def contexts, do: @contexts

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
      "context" => assigns.context_filter,
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
