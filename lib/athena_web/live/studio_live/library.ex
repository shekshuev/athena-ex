defmodule AthenaWeb.StudioLive.Library do
  @moduledoc """
  LiveView for managing reusable content templates (Library Blocks).

  Displays a paginated and searchable list of templates using Streams.
  Handles soft/hard deletion and integrates with `LibraryFormComponent`
  for creating and editing template metadata via a slide-over.
  """
  use AthenaWeb, :live_view

  alias Athena.Content
  alias Athena.Content.LibraryBlock
  alias Athena.Identity
  alias AthenaWeb.StudioLive.LibraryFormComponent

  on_mount {AthenaWeb.Hooks.Permission, "library.read"}

  @doc """
  Initializes the LiveView, setting up the library blocks stream.
  """
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(block_to_delete: nil)
     |> stream(:library_blocks, [])}
  end

  @doc """
  Handles URL parameters for pagination, search, and live actions.
  """
  @spec handle_params(map(), String.t(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  @impl true
  def handle_params(params, _url, socket) do
    search = Map.get(params, "search", "")

    # Configure Flop to search by title
    flop_params =
      if search != "" do
        Map.put(params, "filters", %{
          "0" => %{"field" => "title", "op" => "ilike_and", "value" => search}
        })
      else
        params
      end

    current_user_id = socket.assigns.current_user.id

    case Content.list_library_blocks(flop_params, current_user_id) do
      {:ok, {blocks, meta}} ->
        socket =
          socket
          |> assign(meta: meta, search: search)
          |> stream(:library_blocks, blocks, reset: true)
          |> apply_action(socket.assigns.live_action, params)

        {:noreply, socket}

      {:error, _meta} ->
        {:noreply, push_patch(socket, to: ~p"/studio/library")}
    end
  end

  defp apply_action(socket, :index, _params) do
    assign(socket, page_title: gettext("Library"), library_block: nil)
  end

  defp apply_action(socket, :new, _params) do
    if Identity.can?(socket.assigns.current_user, "library.create") do
      assign(socket, page_title: gettext("Create Template"), library_block: %LibraryBlock{})
    else
      socket
      |> put_flash(:error, gettext("You don't have permission to create templates."))
      |> push_patch(to: ~p"/studio/library")
    end
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    if Identity.can?(socket.assigns.current_user, "library.update") do
      case Content.get_library_block(id) do
        {:ok, block} -> assign(socket, page_title: gettext("Edit Template"), library_block: block)
        _ -> push_patch(socket, to: ~p"/studio/library")
      end
    else
      socket
      |> put_flash(:error, gettext("You don't have permission to edit templates."))
      |> push_patch(to: ~p"/studio/library")
    end
  end

  @doc """
  Handles UI events such as searching and block deletion confirmations.
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

    {:noreply, push_patch(socket, to: ~p"/studio/library?#{params}")}
  end

  def handle_event("delete_click", %{"id" => id}, socket) do
    if Identity.can?(socket.assigns.current_user, "library.delete") do
      {:ok, block} = Content.get_library_block(id)
      {:noreply, assign(socket, block_to_delete: block)}
    else
      {:noreply,
       socket
       |> put_flash(:error, gettext("You don't have permission to delete templates."))
       |> push_patch(to: ~p"/studio/library")}
    end
  end

  def handle_event("confirm_delete", _, %{assigns: %{block_to_delete: block}} = socket) do
    case Content.delete_library_block(block) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Template deleted successfully"))
         |> stream_delete(:library_blocks, block)
         |> assign(block_to_delete: nil)}

      {:error, _} ->
        {:noreply, socket |> put_flash(:error, gettext("Failed to delete template"))}
    end
  end

  def handle_event("cancel_delete", _, socket) do
    {:noreply, assign(socket, block_to_delete: nil)}
  end

  @impl true
  def handle_info({LibraryFormComponent, {:saved, block}}, socket) do
    {:noreply, stream_insert(socket, :library_blocks, block)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex justify-between items-center">
        <div>
          <h1 class="text-2xl font-display font-bold text-base-content">{gettext("Library")}</h1>
          <p class="text-base-content/60">
            {gettext("Manage reusable content templates and quiz questions.")}
          </p>
        </div>
        <.button
          :if={Identity.can?(@current_user, "library.create")}
          patch={~p"/studio/library/new"}
          class="btn btn-primary"
        >
          <.icon name="hero-plus" class="size-5" />
          {gettext("Create Template")}
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
              placeholder={gettext("Search templates...")}
              class="input input-bordered w-full pl-10"
              phx-debounce="500"
            />
          </div>
        </.form>
      </div>

      <.table id="library-blocks" rows={@streams.library_blocks}>
        <:col :let={{_id, block}} label={gettext("Title")}>
          <span class="font-bold">{block.title}</span>
        </:col>
        <:col :let={{_id, block}} label={gettext("Type")}>
          <div class="badge badge-outline badge-sm uppercase font-bold">
            {Atom.to_string(block.type)}
          </div>
        </:col>
        <:col :let={{_id, block}} label={gettext("Tags")}>
          <div class="flex flex-wrap gap-1">
            <span :for={tag <- block.tags || []} class="badge badge-neutral badge-sm">
              {tag}
            </span>
            <span :if={block.tags == []} class="text-xs opacity-50">—</span>
          </div>
        </:col>
        <:col :let={{_id, block}} label={gettext("Created At")}>
          <span class="text-sm opacity-60">{Calendar.strftime(block.inserted_at, "%d.%m.%Y")}</span>
        </:col>
        <:action :let={{_id, block}}>
          <div class="flex justify-end gap-2">
            <.button
              navigate="#"
              class="btn btn-primary btn-xs btn-square btn-soft"
              title={gettext("Open Editor")}
              disabled
            >
              <.icon name="hero-document-text" class="size-4" />
            </.button>

            <.button
              :if={Identity.can?(@current_user, "library.update")}
              patch={~p"/studio/library/#{block.id}/edit"}
              class="btn btn-ghost btn-xs btn-square"
              title={gettext("Edit Metadata")}
            >
              <.icon name="hero-pencil-square" class="size-4" />
            </.button>

            <.button
              :if={Identity.can?(@current_user, "library.delete")}
              type="button"
              phx-click="delete_click"
              phx-value-id={block.id}
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
          path_fn={fn p -> ~p"/studio/library?#{%{"page" => p, "search" => @search}}" end}
        />
      </div>

      <.slide_over
        id="library-slideover"
        show={@live_action in [:new, :edit]}
        title={@page_title}
        on_close={JS.patch(~p"/studio/library")}
      >
        <.live_component
          :if={@library_block}
          module={LibraryFormComponent}
          id={@library_block.id || :new}
          action={@live_action}
          library_block={@library_block}
          current_user={@current_user}
          patch={~p"/studio/library"}
        />
      </.slide_over>

      <.modal
        id="delete-library-modal"
        show={@block_to_delete != nil}
        title={gettext("Delete Template")}
        description={
          gettext(
            "Are you sure you want to permanently delete this template? This action cannot be undone."
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
