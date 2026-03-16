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
           uploading_media_type: nil
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

  def handle_event("add_section", _, socket) do
    course = socket.assigns.course

    attrs = %{
      "title" => gettext("New Section"),
      "course_id" => course.id,
      "owner_id" => socket.assigns.current_user.id
    }

    case Content.create_section(attrs) do
      {:ok, new_section} ->
        updated_sections = socket.assigns.sections ++ [new_section]

        {:noreply,
         socket
         |> assign(sections: updated_sections, active_section_id: new_section.id)
         |> put_flash(:info, gettext("Section added"))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to add section"))}
    end
  end

  def handle_event("update_section_meta", %{"title" => title}, socket) do
    section = find_section_in_tree(socket.assigns.sections, socket.assigns.active_section_id)

    {:ok, _updated_section} = Content.update_section(section, %{"title" => title})

    updated_sections = Content.get_course_tree(socket.assigns.course.id)
    {:noreply, assign(socket, sections: updated_sections)}
  end

  def handle_event(
        "reorder",
        %{"id" => _id, "new_index" => _new_index, "old_index" => _old_index},
        socket
      ) do
    # TODO: Implement section reordering in the database
    {:noreply, socket}
  end

  def handle_event("delete_section", %{"id" => id}, socket) do
    section = find_section_in_tree(socket.assigns.sections, id)
    {:ok, _} = Content.delete_section(section)

    updated_sections = Content.get_course_tree(socket.assigns.course.id)
    {:noreply, assign(socket, sections: updated_sections, active_section_id: nil, blocks: [])}
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

  def handle_event("delete_block", %{"id" => id}, socket) do
    block = Enum.find(socket.assigns.blocks, &(&1.id == id))
    {:ok, _} = Content.delete_block(block)

    updated_blocks = Enum.reject(socket.assigns.blocks, &(&1.id == id))
    {:noreply, assign(socket, blocks: updated_blocks, active_block_id: nil)}
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
            <button
              type="button"
              phx-click="cancel-upload"
              phx-value-ref={entry.ref}
              class="text-error"
            >
              <.icon name="hero-x-mark" class="size-4" />
            </button>
          </div>

          <div class="modal-action">
            <button type="button" class="btn btn-ghost" phx-click="cancel_upload">
              {gettext("Cancel")}
            </button>
            <button type="submit" class="btn btn-primary" disabled={@uploads.media.entries == []}>
              {gettext("Upload")}
            </button>
          </div>
        </.form>
      </.modal>
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
end
