defmodule AthenaWeb.FileLive.Index do
  @moduledoc """
  Personal cloud storage: a searchable, paginated grid of the current
  user's own files, with upload/download/delete and a storage-quota
  progress bar. Every authenticated account manages its own files here —
  unlike `AthenaWeb.AdminLive.Files`, access does not depend on any
  `files.*` permission.
  """
  use AthenaWeb, :live_view

  alias Athena.Media
  alias AthenaWeb.FileLive.PersonalUploadComponent

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(show_upload: false, file_to_delete: nil)
     |> stream(:files, [])}
  end

  @impl true
  def handle_params(params, _url, socket) do
    search = Map.get(params, "search", "")

    flop_params =
      if search != "" do
        Map.put(params, "filters", %{
          "0" => %{"field" => "original_name", "op" => "ilike_and", "value" => search}
        })
      else
        params
      end

    case Media.list_personal_files(socket.assigns.current_user, flop_params) do
      {:ok, {files, meta}} ->
        {:noreply,
         socket
         |> assign(meta: meta, search: search)
         |> assign_usage()
         |> stream(:files, files, reset: true)}

      {:error, _meta} ->
        {:noreply, push_patch(socket, to: ~p"/files")}
    end
  end

  defp assign_usage(socket) do
    %{id: id, role_id: role_id} = socket.assigns.current_user
    assign(socket, usage: Media.get_usage(id, role_id))
  end

  @impl true
  def handle_event("search", %{"search" => search}, socket) do
    params = build_query_params(socket.assigns, %{"search" => search, "page" => 1})
    {:noreply, push_patch(socket, to: ~p"/files?#{params}")}
  end

  def handle_event("update_page_size", %{"page_size" => size}, socket) do
    params = build_query_params(socket.assigns, %{"page_size" => size, "page" => 1})
    {:noreply, push_patch(socket, to: ~p"/files?#{params}")}
  end

  def handle_event("open_upload", _params, socket) do
    {:noreply, assign(socket, show_upload: true)}
  end

  def handle_event("close_upload", _params, socket) do
    {:noreply, assign(socket, show_upload: false)}
  end

  def handle_event("delete_click", %{"id" => id}, socket) do
    current_user = socket.assigns.current_user

    case Media.get_file(id) do
      %{owner_id: owner_id} = file when owner_id == current_user.id ->
        {:noreply, assign(socket, file_to_delete: file)}

      _ ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("File not found."))
         |> assign(file_to_delete: nil)}
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
        {:noreply,
         socket
         |> put_flash(:info, gettext("File deleted successfully"))
         |> stream_delete(:files, file)
         |> assign(file_to_delete: nil)
         |> assign_usage()}

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Failed to delete file"))
         |> assign(file_to_delete: nil)}
    end
  end

  @impl true
  def handle_info({PersonalUploadComponent, {:saved, results}}, socket) do
    {successes, failures} =
      Enum.split_with(results, fn
        {:ok, {:ok, _file}} -> true
        _ -> false
      end)

    socket =
      case {length(successes), length(failures)} do
        {n, 0} when n > 0 ->
          put_flash(
            socket,
            :info,
            ngettext("1 file uploaded", "%{count} files uploaded", n, count: n)
          )

        {0, f} when f > 0 ->
          put_flash(socket, :error, gettext("Upload failed"))

        {n, f} ->
          put_flash(
            socket,
            :info,
            gettext("%{ok} uploaded, %{failed} failed", ok: n, failed: f)
          )
      end

    case Media.list_personal_files(socket.assigns.current_user, %{
           "page" => socket.assigns.meta.current_page,
           "page_size" => socket.assigns.meta.page_size
         }) do
      {:ok, {files, meta}} ->
        {:noreply,
         socket
         |> assign(meta: meta, show_upload: false)
         |> assign_usage()
         |> stream(:files, files, reset: true)}

      {:error, _meta} ->
        {:noreply, assign(socket, show_upload: false)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.page_container size="wide" class="space-y-6">
      <div class="flex justify-between items-center">
        <div>
          <h1 class="text-2xl font-display font-bold text-base-content">{gettext("My Files")}</h1>
          <p class="text-base-content/60">{gettext("Your personal storage space.")}</p>
        </div>
        <.button
          type="button"
          variant="primary"
          phx-click="open_upload"
          disabled={@usage.used >= @usage.limit}
          title={if @usage.used >= @usage.limit, do: gettext("Your storage quota is full"), else: nil}
        >
          <.icon name="hero-cloud-arrow-up" class="size-5" />
          {gettext("Upload")}
        </.button>
      </div>

      <div class="bg-base-100 border border-base-300 rounded-lg p-4">
        <div class="flex justify-between text-sm font-bold mb-2">
          <span>{gettext("Storage used")}</span>
          <span class="text-base-content/70">
            {Media.format_bytes(@usage.used)} / {Media.format_bytes(@usage.limit)}
          </span>
        </div>
        <div class="w-full bg-base-300 rounded-sm h-3 overflow-hidden">
          <div
            class={["h-full transition-all duration-300", quota_tone(@usage.used, @usage.limit)]}
            style={"width: #{quota_pct(@usage.used, @usage.limit)}%"}
          >
          </div>
        </div>
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
              placeholder={gettext("Search files...")}
              class="input input-bordered w-full pl-10"
              phx-debounce="500"
            />
          </div>
        </.form>
      </div>

      <% path_fn = fn overrides -> ~p"/files?#{build_query_params(assigns, overrides)}" end %>

      <div
        id="files-grid"
        phx-update="stream"
        class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4 gap-4"
      >
        <div
          :for={{dom_id, file} <- @streams.files}
          id={dom_id}
          class="bg-base-100 border border-base-300 rounded-lg p-4 flex flex-col gap-3"
        >
          <div class="flex items-start justify-between">
            <div class="p-2 bg-base-200/60 rounded-sm text-primary shrink-0">
              <.file_type_icon mime_type={file.mime_type} class="size-6" />
            </div>
            <div class="flex gap-1">
              <.icon_button
                href={~p"/media/#{file.key}"}
                icon="hero-arrow-down-tray"
                label={gettext("Download")}
              />
              <.icon_button
                type="button"
                phx-click="delete_click"
                phx-value-id={file.id}
                icon="hero-trash"
                label={gettext("Delete")}
                variant="danger"
              />
            </div>
          </div>
          <div class="min-w-0">
            <div class="text-sm font-bold text-base-content truncate" title={file.original_name}>
              {file.original_name}
            </div>
            <div class="text-xs font-medium text-base-content/50 uppercase tracking-wider">
              {Media.format_bytes(file.size)} · {Calendar.strftime(file.inserted_at, "%d.%m.%Y")}
            </div>
          </div>
        </div>
      </div>

      <.empty_state
        :if={@meta.total_count == 0}
        icon="hero-folder-open"
        title={gettext("No files yet")}
        description={gettext("Upload your first file to get started.")}
      />

      <div class="flex justify-end">
        <.pagination meta={@meta} path_fn={path_fn} />
      </div>

      <.live_component
        :if={@show_upload}
        module={PersonalUploadComponent}
        id="personal-upload"
        current_user={@current_user}
        usage={@usage}
      />

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
