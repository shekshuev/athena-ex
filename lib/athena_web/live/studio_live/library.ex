defmodule AthenaWeb.StudioLive.Library do
  @moduledoc """
  LiveView for managing reusable content templates (Library Blocks).
  Displays a visual grid gallery of templates using streams and universal content blocks.
  """
  use AthenaWeb, :live_view

  alias Athena.Content
  alias Athena.Content.LibraryBlock
  alias Athena.Identity
  alias AthenaWeb.StudioLive.LibraryFormComponent
  import AthenaWeb.BlockComponents

  on_mount {AthenaWeb.Hooks.Permission, "library.read"}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(block_to_delete: nil)
     |> stream(:library_blocks, [])}
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

    case Content.list_library_blocks(socket.assigns.current_user, flop_params) do
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
      case Content.get_library_block(socket.assigns.current_user, id) do
        {:ok, block} -> assign(socket, page_title: gettext("Edit Template"), library_block: block)
        _ -> push_patch(socket, to: ~p"/studio/library")
      end
    else
      socket
      |> put_flash(:error, gettext("You don't have permission to edit templates."))
      |> push_patch(to: ~p"/studio/library")
    end
  end

  @impl true
  def handle_event("search", %{"search" => search}, socket) do
    params = %{"search" => search, "page" => 1, "page_size" => socket.assigns.meta.page_size}
    {:noreply, push_patch(socket, to: ~p"/studio/library?#{params}")}
  end

  def handle_event("delete_click", %{"id" => id}, socket) do
    if Identity.can?(socket.assigns.current_user, "library.delete") do
      {:ok, block} = Content.get_library_block(socket.assigns.current_user, id)
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
          class="btn btn-primary shadow-lg shadow-primary/20"
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

      <div class="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 gap-8 mt-8">
        <div
          :for={{dom_id, block} <- @streams.library_blocks}
          id={dom_id}
          class="card bg-base-100 border border-base-200 shadow-sm hover:shadow-xl hover:border-primary/40 transition-all duration-300 overflow-hidden group flex flex-col"
        >
          <div class="h-48 bg-linear-to-br from-base-200 to-base-300 relative overflow-hidden flex items-center justify-center pointer-events-none select-none">
            <div class="origin-top-left w-[140%] scale-[0.70] p-6 opacity-60 group-hover:opacity-100 transition-opacity duration-300">
              <.content_block block={block} mode={:play} answers={%{}} />
            </div>
            <div class="absolute bottom-0 left-0 right-0 h-24 bg-linear-to-t from-base-100 to-transparent z-10">
            </div>
          </div>

          <div class="card-body p-6 grow gap-4">
            <div>
              <div class="flex justify-between items-start gap-4">
                <h2
                  class="card-title text-xl font-display font-bold group-hover:text-primary transition-colors line-clamp-2"
                  title={block.title}
                >
                  {block.title}
                </h2>
                <span class="badge badge-sm font-bold shadow-sm border-0 bg-base-200 text-base-content/70 uppercase tracking-widest text-[10px] shrink-0 mt-1">
                  {Atom.to_string(block.type) |> String.replace("_", " ")}
                </span>
              </div>

              <div class="flex flex-wrap gap-1 mt-3">
                <span :for={tag <- block.tags || []} class="badge badge-xs badge-neutral">{tag}</span>
                <span :if={block.tags == []} class="text-xs opacity-50 italic">
                  {gettext("No tags")}
                </span>
              </div>
            </div>

            <div class="mt-auto pt-6 flex items-center justify-between border-t border-base-200/50">
              <div class="text-xs text-base-content/50 font-mono">
                {Calendar.strftime(block.inserted_at, "%d.%m.%Y")}
              </div>

              <div class="flex items-center gap-2">
                <.button
                  :if={Identity.can?(@current_user, "library.update")}
                  patch={~p"/studio/library/#{block.id}/edit"}
                  class="btn btn-ghost btn-sm btn-square text-base-content/70"
                  title={gettext("Edit Metadata")}
                >
                  <.icon name="hero-pencil-square" class="size-4" />
                </.button>

                <.button
                  :if={Identity.can?(@current_user, "library.delete")}
                  type="button"
                  phx-click="delete_click"
                  phx-value-id={block.id}
                  class="btn btn-ghost btn-sm btn-square text-error hover:bg-error/10"
                  title={gettext("Delete")}
                >
                  <.icon name="hero-trash" class="size-4" />
                </.button>

                <.link
                  navigate={~p"/studio/library/#{block.id}/editor"}
                  class="btn btn-primary btn-sm group-hover:pr-3 transition-all ml-1"
                >
                  {gettext("Edit")}
                  <.icon
                    name="hero-arrow-right"
                    class="size-4 opacity-0 -ml-4 group-hover:opacity-100 group-hover:ml-0 transition-all duration-300"
                  />
                </.link>
              </div>
            </div>
          </div>
        </div>
      </div>

      <div class="flex justify-end mt-8">
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
