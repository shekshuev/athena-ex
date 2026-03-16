defmodule AthenaWeb.StudioLive.Builder do
  @moduledoc """
  The mother of all views: Course Builder Studio.

  Handles the layout and global state for the Sidebar, Canvas, and Inspector.
  Manages the creation, reordering, and metadata updates for both sections
  and content blocks using real-time Phoenix LiveView events.
  """
  use AthenaWeb, :live_view

  alias Athena.Content
  alias Athena.Content.Block

  on_mount {AthenaWeb.Hooks.Permission, "courses.update"}

  @doc """
  Initializes the LiveView, loading the course, its section tree, and blocks
  for the active section. Configures media upload constraints.
  """
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  @impl true
  def mount(%{"id" => course_id}, _session, socket) do
    case Content.get_course(course_id) do
      {:ok, course} ->
        sections = Content.get_course_tree(course.id)
        active_section_id = if sections != [], do: hd(sections).id, else: nil

        blocks =
          if active_section_id do
            Content.list_blocks_by_section(active_section_id)
          else
            []
          end

        {:ok,
         socket
         |> assign(
           course: course,
           sections: sections,
           active_section_id: active_section_id,
           active_block_id: nil,
           blocks: blocks,
           uploading_for_block: nil,
           uploading_media_type: nil,
           viewing_parent_id: nil,
           moving_section_id: nil,
           quick_nav_open: false,
           section_to_delete: nil,
           block_to_delete: nil
         )
         |> allow_upload(:media,
           accept: ~w(.jpg .jpeg .png .gif .webp .mp4 .mov .webm),
           max_entries: 1,
           max_file_size: 50_000_000
         )}

      _ ->
        {:ok, push_navigate(socket, to: ~p"/studio/courses")}
    end
  end

  @doc """
  Handles URL parameters for the builder view.
  """
  @spec handle_params(map(), String.t(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @doc """
  Handles UI events for managing sections, blocks, and media uploads.
  """
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}

  # --- SECTION EVENTS ---

  @impl true
  def handle_event("select_section", %{"id" => id}, socket) do
    blocks = Content.list_blocks_by_section(id)
    {:noreply, assign(socket, active_section_id: id, active_block_id: nil, blocks: blocks)}
  end

  @impl true
  def handle_event("add_section", %{"parent_id" => parent_id}, socket) do
    course = socket.assigns.course
    clean_parent_id = if parent_id == "", do: nil, else: parent_id

    attrs = %{
      "title" => gettext("New Lesson"),
      "course_id" => course.id,
      "owner_id" => socket.assigns.current_user.id,
      "parent_id" => clean_parent_id
    }

    case Content.create_section(attrs) do
      {:ok, new_section} ->
        updated_sections = Content.get_course_tree(course.id)

        {:noreply,
         socket
         |> assign(
           sections: updated_sections,
           active_section_id: new_section.id,
           viewing_parent_id: clean_parent_id
         )
         |> put_flash(:info, gettext("Section added"))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to add section"))}
    end
  end

  def handle_event("add_section", _, socket) do
    handle_event("add_section", %{"parent_id" => socket.assigns.viewing_parent_id || ""}, socket)
  end

  def handle_event("update_section_meta", %{"title" => title}, socket) do
    section = find_section_in_tree(socket.assigns.sections, socket.assigns.active_section_id)

    {:ok, _updated_section} = Content.update_section(section, %{"title" => title})

    updated_sections = Content.get_course_tree(socket.assigns.course.id)
    {:noreply, assign(socket, sections: updated_sections)}
  end

  def handle_event("reorder_section", %{"id" => id, "new_index" => new_index}, socket) do
    section = find_section_in_tree(socket.assigns.sections, id)

    if section do
      {:ok, _} = Content.reorder_section(section, new_index)

      updated_sections = Content.get_course_tree(socket.assigns.course.id)

      {:noreply, assign(socket, sections: updated_sections)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("delete_section_click", %{"id" => id}, socket) do
    section = find_section_in_tree(socket.assigns.sections, id)
    {:noreply, assign(socket, section_to_delete: section)}
  end

  def handle_event("confirm_delete_section", _, socket) do
    section = socket.assigns.section_to_delete
    {:ok, _} = Content.delete_section(section)
    updated_sections = Content.get_course_tree(socket.assigns.course.id)

    {:noreply,
     socket
     |> put_flash(:info, gettext("Section deleted"))
     |> assign(
       sections: updated_sections,
       section_to_delete: nil,
       active_section_id: nil,
       blocks: []
     )}
  end

  def handle_event("drill_down", %{"id" => id}, socket) do
    {:noreply, assign(socket, viewing_parent_id: id)}
  end

  def handle_event("drill_up", %{"id" => id}, socket) do
    parent_id = if id == "", do: nil, else: id
    {:noreply, assign(socket, viewing_parent_id: parent_id)}
  end

  def handle_event("open_quick_nav", _, socket) do
    {:noreply, assign(socket, quick_nav_open: true)}
  end

  def handle_event("close_quick_nav", _, socket) do
    {:noreply, assign(socket, quick_nav_open: false)}
  end

  def handle_event("jump_to_root", _, socket) do
    {:noreply, assign(socket, viewing_parent_id: nil, quick_nav_open: false)}
  end

  def handle_event("jump_to_section", %{"id" => id}, socket) do
    section = find_section_in_tree(socket.assigns.sections, id)

    if section do
      blocks = Content.list_blocks_by_section(id)

      {:noreply,
       socket
       |> assign(
         active_section_id: id,
         active_block_id: nil,
         viewing_parent_id: section.parent_id,
         blocks: blocks,
         quick_nav_open: false
       )}
    else
      {:noreply, assign(socket, quick_nav_open: false)}
    end
  end

  def handle_event("open_move_modal", %{"id" => id}, socket) do
    {:noreply, assign(socket, moving_section_id: id)}
  end

  def handle_event("cancel_move", _, socket) do
    {:noreply, assign(socket, moving_section_id: nil)}
  end

  def handle_event("move_section", %{"target_id" => target_id}, socket) do
    section_id = socket.assigns.moving_section_id
    clean_target_id = if target_id == "root", do: nil, else: target_id

    section = find_section_in_tree(socket.assigns.sections, section_id)

    if section do
      {:ok, _} = Content.update_section(section, %{"parent_id" => clean_target_id})

      updated_sections = Content.get_course_tree(socket.assigns.course.id)

      {:noreply,
       socket
       |> assign(sections: updated_sections, moving_section_id: nil)
       |> put_flash(:info, gettext("Moved successfully"))}
    else
      {:noreply, socket}
    end
  end

  # --- BLOCK EVENTS ---

  def handle_event("select_block", %{"id" => id}, socket) do
    {:noreply, assign(socket, active_block_id: id)}
  end

  def handle_event("add_text_block", _, socket) do
    attrs = %{
      "type" => "text",
      "content" => %{"type" => "doc", "content" => [%{"type" => "paragraph"}]},
      "section_id" => socket.assigns.active_section_id
    }

    case Content.create_block(attrs) do
      {:ok, block} ->
        updated_blocks = socket.assigns.blocks ++ [block]
        {:noreply, assign(socket, blocks: updated_blocks, active_block_id: block.id)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to create block"))}
    end
  end

  def handle_event("add_code_block", _, socket) do
    attrs = %{
      "type" => "code",
      "content" => %{"code" => "IO.puts(:hello)"},
      "section_id" => socket.assigns.active_section_id
    }

    case Content.create_block(attrs) do
      {:ok, block} ->
        updated_blocks = socket.assigns.blocks ++ [block]
        {:noreply, assign(socket, blocks: updated_blocks, active_block_id: block.id)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to create block"))}
    end
  end

  def handle_event("update_content", %{"id" => id, "content" => content}, socket) do
    block = Enum.find(socket.assigns.blocks, &(&1.id == id))

    if block do
      {:ok, updated_block} = Content.update_block(block, %{"content" => content})
      {:noreply, assign(socket, blocks: replace_block(socket.assigns.blocks, updated_block))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("reorder_block", %{"id" => id, "new_index" => new_index}, socket) do
    block = Enum.find(socket.assigns.blocks, &(&1.id == id))

    if block do
      {:ok, _updated_block} = Content.reorder_block(block, new_index)

      blocks = Content.list_blocks_by_section(socket.assigns.active_section_id)
      {:noreply, assign(socket, blocks: blocks)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("update_block_meta", params, socket) do
    id = params["id"]
    block = Enum.find(socket.assigns.blocks, &(&1.id == id))

    if block do
      meta_params = Map.drop(params, ["id", "_csrf_token", "_target"])
      new_content = Map.merge(block.content || %{}, meta_params)

      {:ok, updated_block} = Content.update_block(block, %{"content" => new_content})
      {:noreply, assign(socket, blocks: replace_block(socket.assigns.blocks, updated_block))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("delete_block_click", %{"id" => id}, socket) do
    block = Enum.find(socket.assigns.blocks, &(&1.id == id))
    {:noreply, assign(socket, block_to_delete: block)}
  end

  def handle_event("confirm_delete_block", _, socket) do
    block = socket.assigns.block_to_delete
    {:ok, _} = Content.delete_block(block)
    updated_blocks = Enum.reject(socket.assigns.blocks, &(&1.id == block.id))

    {:noreply,
     socket
     |> put_flash(:info, gettext("Block deleted"))
     |> assign(blocks: updated_blocks, block_to_delete: nil, active_block_id: nil)}
  end

  # --- MEDIA UPLOAD EVENTS ---

  def handle_event(
        "request_media_upload",
        %{"block_id" => block_id, "media_type" => media_type},
        socket
      ) do
    {:noreply, assign(socket, uploading_for_block: block_id, uploading_media_type: media_type)}
  end

  def handle_event("validate_media", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_upload", _, socket) do
    {:noreply, assign(socket, uploading_for_block: nil)}
  end

  def handle_event("save_media", _params, socket) do
    block_id = socket.assigns.uploading_for_block
    media_type = socket.assigns.uploading_media_type || "image"

    uploaded_urls =
      consume_uploaded_entries(socket, :media, fn %{path: path}, entry ->
        uploads_dir = Path.join(["priv", "static", "uploads"])
        File.mkdir_p!(uploads_dir)

        dest = Path.join([uploads_dir, "#{entry.uuid}-#{entry.client_name}"])
        File.cp!(path, dest)

        url = "/uploads/#{entry.uuid}-#{entry.client_name}"
        {:ok, url}
      end)

    url = hd(uploaded_urls)

    {:noreply,
     socket
     |> push_event("insert_media", %{url: url, block_id: block_id, type: media_type})
     |> assign(uploading_for_block: nil, uploading_media_type: nil)}
  end

  @impl true
  def render(assigns) do
    active_section = find_section_in_tree(assigns.sections, assigns.active_section_id)
    active_block = Enum.find(assigns.blocks, &(&1.id == assigns.active_block_id))

    assigns =
      assigns
      |> assign(active_section: active_section, active_block: active_block)

    ~H"""
    <div class="fixed inset-0 pt-16 lg:pt-0 z-50 flex bg-base-200">
      <div class="w-80 flex flex-col bg-base-100 border-r border-base-300 shrink-0 z-10">
        <div class="p-4 border-b border-base-300 flex items-center justify-between">
          <h2 class="font-bold truncate" title={@course.title}>{@course.title}</h2>
          <.link navigate={~p"/studio/courses"} class="btn btn-ghost btn-xs btn-square">
            <.icon name="hero-x-mark" class="size-4" />
          </.link>
        </div>

        <div class="flex-1 overflow-hidden p-4 flex flex-col">
          <.live_component
            module={AthenaWeb.StudioLive.Builder.StructureSidebarComponent}
            id="structure-sidebar"
            sections={@sections}
            active_section_id={@active_section_id}
            viewing_parent_id={@viewing_parent_id}
          />
        </div>
      </div>

      <div class="flex-1 flex flex-col relative overflow-hidden bg-base-200">
        <div class="flex-1 flex flex-col relative overflow-hidden bg-base-200">
          <div class="flex-1 overflow-y-auto p-8 relative">
            <div class="max-w-3xl mx-auto min-h-full flex flex-col gap-4">
              <.live_component
                module={AthenaWeb.StudioLive.Builder.CanvasComponent}
                id="canvas-component"
                blocks={@blocks}
                active_section_id={@active_section_id}
                active_block_id={@active_block_id}
              />
            </div>
          </div>
        </div>
      </div>

      <div class="w-80 flex flex-col bg-base-100 border-l border-base-300 shrink-0 z-10">
        <div class="p-4 border-b border-base-300">
          <h3 class="font-bold text-sm uppercase tracking-wider text-base-content/70">
            {gettext("Inspector")}
          </h3>
        </div>

        <div class="flex-1 overflow-hidden p-4 flex flex-col">
          <.live_component
            module={AthenaWeb.StudioLive.Builder.InspectorComponent}
            id="inspector-component"
            active_section={@active_section}
            active_block={@active_block}
          />
        </div>
      </div>

      <.modal
        id="media-upload-modal"
        show={@uploading_for_block != nil}
        title={gettext("Upload Media")}
        on_cancel={JS.push("cancel_upload")}
      >
        <.form for={nil} id="upload-form" phx-submit="save_media" phx-change="validate_media">
          <div
            class="border-2 border-dashed border-base-300 rounded-lg p-8 text-center"
            phx-drop-target={@uploads.media.ref}
          >
            <.live_file_input upload={@uploads.media} class="sr-only" id="media-upload-input" />
            <label for="media-upload-input" class="cursor-pointer flex flex-col items-center gap-2">
              <.icon name="hero-cloud-arrow-up" class="size-10 text-primary" />
              <span class="font-bold">{gettext("Click or drag file here")}</span>
              <span class="text-xs text-base-content/50">{gettext("PNG, JPG, GIF up to 10MB")}</span>
            </label>
          </div>

          <div
            :for={entry <- @uploads.media.entries}
            class="mt-4 flex items-center justify-between bg-base-200 p-2 rounded"
          >
            <span class="text-sm truncate">{entry.client_name}</span>
            <.button
              type="button"
              phx-click="cancel-upload"
              phx-value-ref={entry.ref}
              class="text-error bg-transparent border-none shadow-none p-0 hover:bg-transparent"
            >
              <.icon name="hero-x-mark" class="size-4" />
            </.button>
          </div>

          <div class="modal-action">
            <.button type="button" class="btn btn-ghost" phx-click="cancel_upload">
              {gettext("Cancel")}
            </.button>
            <.button type="submit" class="btn btn-primary" disabled={@uploads.media.entries == []}>
              {gettext("Upload")}
            </.button>
          </div>
        </.form>
      </.modal>

      <.modal
        id="move-section-modal"
        show={@moving_section_id != nil}
        title={gettext("Move to...")}
        on_cancel={JS.push("cancel_move")}
      >
        <div class="max-h-[60vh] overflow-y-auto -mx-6 px-6 py-2">
          <.button
            type="button"
            phx-click="move_section"
            phx-value-target_id="root"
            class="w-full justify-start px-3 py-2 hover:bg-base-200 rounded-md flex items-center gap-2 text-sm transition-colors font-medium mb-2 border-b border-base-200 pb-3 bg-transparent border-none shadow-none text-base-content"
          >
            <.icon name="hero-home" class="size-4 text-primary" />
            <span class="truncate">{gettext("Course Root (Top Level)")}</span>
          </.button>

          <.folder_tree_options sections={@sections} moving_section_id={@moving_section_id} />
        </div>
      </.modal>

      <.modal
        id="quick-nav-modal"
        show={@quick_nav_open}
        title={gettext("Course Map")}
        on_cancel={JS.push("close_quick_nav")}
      >
        <div class="max-h-[60vh] overflow-y-auto -mx-6 px-6 py-2">
          <.button
            type="button"
            phx-click="jump_to_root"
            class="w-full justify-start px-3 py-2 hover:bg-base-200 rounded-md flex items-center gap-2 text-sm transition-colors font-medium mb-2 border-b border-base-200 pb-3 bg-transparent border-none shadow-none text-base-content"
          >
            <.icon name="hero-home" class="size-4 text-primary" />
            <span class="truncate">{gettext("View Root Level")}</span>
          </.button>

          <.quick_nav_tree sections={@sections} active_section_id={@active_section_id} />
        </div>
      </.modal>

      <.modal
        :if={@section_to_delete}
        id="delete-section-modal"
        show={@section_to_delete != nil}
        title={gettext("Delete Lesson")}
        description={
          gettext("Are you sure you want to delete '%{title}'? This action cannot be undone.",
            title: @section_to_delete.title
          )
        }
        confirm_label={gettext("Delete")}
        danger={true}
        on_cancel={JS.push("cancel_section_delete")}
        on_confirm={JS.push("confirm_delete_section")}
      />

      <.modal
        :if={@block_to_delete}
        id="delete-block-modal"
        show={@block_to_delete != nil}
        title={gettext("Delete Block")}
        description={gettext("Remove this content block from the lesson?")}
        confirm_label={gettext("Delete")}
        danger={true}
        on_cancel={JS.push("cancel_block_delete")}
        on_confirm={JS.push("confirm_delete_block")}
      />
    </div>
    """
  end

  # --- PRIVATE HELPERS ---

  defp find_section_in_tree(_, nil), do: nil

  defp find_section_in_tree(sections, id) do
    Enum.find_value(sections, fn section ->
      if section.id == id do
        section
      else
        find_section_in_tree(section.children || [], id)
      end
    end)
  end

  defp replace_block(blocks, updated_block) do
    Enum.map(blocks, fn
      %Block{id: id} when id == updated_block.id -> updated_block
      b -> b
    end)
  end

  @doc """
  Recursive component to render a folder tree for the Move To modal.
  """
  def folder_tree_options(assigns) do
    assigns = assign_new(assigns, :level, fn -> 0 end)

    ~H"""
    <div class="space-y-0.5">
      <div :for={section <- @sections}>
        <%= if section.id != @moving_section_id do %>
          <.button
            type="button"
            phx-click="move_section"
            phx-value-target_id={section.id}
            class="w-full justify-start px-3 py-2 hover:bg-base-200 rounded-md flex items-center gap-2 text-sm transition-colors group bg-transparent border-none shadow-none text-base-content font-normal"
            style={"padding-left: #{(@level * 1.5) + 0.75}rem;"}
          >
            <.icon
              name="hero-folder"
              class="size-4 text-base-content/40 group-hover:text-primary transition-colors"
            />
            <span class="truncate">{section.title}</span>
          </.button>

          <.folder_tree_options
            :if={section.children != []}
            sections={section.children}
            moving_section_id={@moving_section_id}
            level={@level + 1}
          />
        <% end %>
      </div>
    </div>
    """
  end

  @doc """
  Recursive component to render the quick navigation tree.
  """
  def quick_nav_tree(assigns) do
    assigns = assign_new(assigns, :level, fn -> 0 end)

    ~H"""
    <div class="space-y-0.5">
      <div :for={section <- @sections}>
        <.button
          type="button"
          phx-click="jump_to_section"
          phx-value-id={section.id}
          class={[
            "w-full justify-start px-3 py-2 rounded-md flex items-center gap-2 text-sm transition-colors group bg-transparent border-none shadow-none font-normal",
            @active_section_id == section.id && "bg-primary/10 text-primary font-bold",
            @active_section_id != section.id && "hover:bg-base-200 text-base-content/80"
          ]}
          style={"padding-left: #{(@level * 1.5) + 0.75}rem;"}
        >
          <.icon
            name={if section.children == [], do: "hero-document", else: "hero-folder"}
            class={[
              "size-4 transition-colors shrink-0",
              @active_section_id == section.id && "text-primary",
              @active_section_id != section.id && "text-base-content/40 group-hover:text-primary"
            ]}
          />
          <span class="truncate">{section.title}</span>
        </.button>

        <.quick_nav_tree
          :if={section.children != []}
          sections={section.children}
          active_section_id={@active_section_id}
          level={@level + 1}
        />
      </div>
    </div>
    """
  end
end
