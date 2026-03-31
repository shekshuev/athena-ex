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

  @allowed_image_types ~w(.jpg .jpeg .png .gif .webp)
  @allowed_video_types ~w(.mp4 .mov .webm)
  @allowed_attachment_types ~w(.pdf .doc .docx .xls .xlsx .ppt .pptx .txt .zip .rar .7z)

  @image_max_size 10 * 1024 * 1024
  @video_max_size 500 * 1024 * 1024
  @attachment_max_size 50 * 1024 * 1024

  @image_types_str @allowed_image_types
                   |> Enum.map_join(", ", fn "." <> ext -> String.upcase(ext) end)
  @video_types_str @allowed_video_types
                   |> Enum.map_join(", ", fn "." <> ext -> String.upcase(ext) end)
  @attachment_types_str @allowed_attachment_types
                        |> Enum.map_join(", ", fn "." <> ext -> String.upcase(ext) end)

  @doc """
  Initializes the LiveView, loading the course, its section tree, and blocks
  for the active section. Configures media upload constraints.
  """
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  @impl true
  def mount(%{"id" => course_id}, _session, socket) do
    case Content.get_course(course_id) do
      {:ok, course} ->
        if connected?(socket), do: :timer.send_interval(1000, self(), :tick)
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
           block_to_delete: nil,
           server_now: DateTime.utc_now() |> DateTime.truncate(:second),
           saving_block_to_library: nil,
           library_picker_open: false,
           library_blocks: [],
           library_search: ""
         )
         |> allow_upload(:image_upload,
           accept: @allowed_image_types,
           max_entries: 1,
           max_file_size: @image_max_size,
           external: &presign_upload/2
         )
         |> allow_upload(:video_upload,
           accept: @allowed_video_types,
           max_entries: 1,
           max_file_size: @video_max_size,
           external: &presign_upload/2
         )
         |> allow_upload(:attachment_upload,
           accept: @allowed_attachment_types,
           max_entries: 10,
           max_file_size: @attachment_max_size,
           external: &presign_upload/2
         )}

      _ ->
        {:ok, push_navigate(socket, to: ~p"/studio/courses")}
    end
  end

  @impl true
  def handle_info(:tick, socket) do
    {:noreply, assign(socket, server_now: DateTime.utc_now() |> DateTime.truncate(:second))}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

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

  def handle_event("update_section_meta", %{"section" => section_params}, socket) do
    id = section_params["id"]
    section = find_section_in_tree(socket.assigns.sections, id)

    if section do
      case Content.update_section(section, section_params) do
        {:ok, _updated_section} ->
          updated_sections = Content.get_course_tree(socket.assigns.course.id)
          {:noreply, assign(socket, sections: updated_sections)}

        {:error, _changeset} ->
          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
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

  def handle_event("cancel_section_delete", _, socket) do
    {:noreply, assign(socket, section_to_delete: nil)}
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

    create_and_assign_block(socket, attrs)
  end

  def handle_event("add_code_block", _, socket) do
    attrs = %{
      "type" => "code",
      "content" => %{"code" => "IO.puts(:hello)"},
      "section_id" => socket.assigns.active_section_id
    }

    create_and_assign_block(socket, attrs)
  end

  def handle_event("add_quiz_question_block", _, socket) do
    attrs = %{
      "type" => "quiz_question",
      "content" => %{
        "question_type" => "open",
        "body" => %{"type" => "doc", "content" => [%{"type" => "paragraph"}]},
        "options" => []
      },
      "section_id" => socket.assigns.active_section_id
    }

    create_and_assign_block(socket, attrs, gettext("Failed to create quiz block"))
  end

  def handle_event("add_image_block", _, socket) do
    attrs = %{
      "type" => "image",
      "content" => %{"url" => nil, "alt" => "", "caption" => ""},
      "section_id" => socket.assigns.active_section_id
    }

    create_and_assign_block(socket, attrs, gettext("Failed to create image block"))
  end

  def handle_event("add_video_block", _, socket) do
    attrs = %{
      "type" => "video",
      "content" => %{"url" => nil, "poster_url" => nil, "controls" => true},
      "section_id" => socket.assigns.active_section_id
    }

    create_and_assign_block(socket, attrs, gettext("Failed to create video block"))
  end

  def handle_event("add_attachment_block", _, socket) do
    attrs = %{
      "type" => "attachment",
      "content" => %{
        "description" => %{"type" => "doc", "content" => [%{"type" => "paragraph"}]},
        "files" => []
      },
      "section_id" => socket.assigns.active_section_id
    }

    create_and_assign_block(socket, attrs, gettext("Failed to create attachment block"))
  end

  def handle_event("add_quiz_option", %{"id" => block_id}, socket) do
    block = Enum.find(socket.assigns.blocks, &(&1.id == block_id))

    if block do
      content_map = normalize_content(block.content || %{})
      options = Map.get(content_map, "options", [])

      new_option = %{
        "id" => Ecto.UUID.generate(),
        "text" => "",
        "is_correct" => false,
        "explanation" => ""
      }

      new_content = Map.put(content_map, "options", options ++ [new_option])
      {:ok, updated_block} = Content.update_block(block, %{"content" => new_content})
      {:noreply, assign(socket, blocks: replace_block(socket.assigns.blocks, updated_block))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("remove_quiz_option", %{"id" => block_id, "option_id" => option_id}, socket) do
    block = Enum.find(socket.assigns.blocks, &(&1.id == block_id))

    if block do
      content_map = normalize_content(block.content || %{})
      options = Map.get(content_map, "options", []) |> Enum.reject(&(&1["id"] == option_id))
      new_content = Map.put(content_map, "options", options)

      {:ok, updated_block} = Content.update_block(block, %{"content" => new_content})
      {:noreply, assign(socket, blocks: replace_block(socket.assigns.blocks, updated_block))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("update_quiz_content", %{"block_id" => id} = params, socket) do
    block = Enum.find(socket.assigns.blocks, &(&1.id == id))

    if block do
      content_map = normalize_content(block.content || %{})

      content_map =
        if correct_answer = params["correct_answer"] do
          Map.put(content_map, "correct_answer", correct_answer)
        else
          content_map
        end

      content_map =
        if opts = params["options"] do
          Map.put(content_map, "options", parse_quiz_options(opts, params["correct_option_id"]))
        else
          content_map
        end

      case Content.update_block(block, %{"content" => content_map}) do
        {:ok, updated_block} ->
          {:noreply, assign(socket, blocks: replace_block(socket.assigns.blocks, updated_block))}

        {:error, changeset} ->
          {:noreply,
           assign(
             socket,
             blocks: replace_block(socket.assigns.blocks, Ecto.Changeset.apply_changes(changeset))
           )}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("update_content", %{"id" => id, "content" => text_content}, socket) do
    block = Enum.find(socket.assigns.blocks, &(&1.id == id))

    if block do
      content_map = normalize_content(block.content || %{})

      new_content =
        case block.type do
          :attachment -> Map.put(content_map, "description", text_content)
          :quiz_question -> Map.put(content_map, "body", text_content)
          _ -> text_content
        end

      {:ok, updated_block} = Content.update_block(block, %{"content" => new_content})
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

  def handle_event("update_block_meta", %{"block" => block_params}, socket) do
    id = block_params["id"]
    block = Enum.find(socket.assigns.blocks, &(&1.id == id))

    if block do
      content_map = normalize_content(block.content || %{})
      content_overrides = Map.get(block_params, "content", %{})

      content_overrides = apply_quiz_meta_overrides(content_map, content_overrides)

      new_content = Map.merge(content_map, content_overrides)
      final_params = Map.put(block_params, "content", new_content)

      case Content.update_block(block, final_params) do
        {:ok, updated_block} ->
          {:noreply, assign(socket, blocks: replace_block(socket.assigns.blocks, updated_block))}

        {:error, changeset} ->
          in_memory_block = Ecto.Changeset.apply_changes(changeset)

          {:noreply,
           assign(socket, blocks: replace_block(socket.assigns.blocks, in_memory_block))}
      end
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

  def handle_event("cancel_block_delete", _, socket) do
    {:noreply, assign(socket, block_to_delete: nil)}
  end

  def handle_event("delete_attachment", %{"block_id" => block_id, "url" => url}, socket) do
    block = Enum.find(socket.assigns.blocks, &(&1.id == block_id))

    if block do
      content_map = normalize_content(block.content || %{})
      files = Map.get(content_map, "files", [])
      new_files = Enum.reject(files, &(&1["url"] == url))

      {:ok, updated_block} =
        Content.update_block(block, %{"content" => Map.put(content_map, "files", new_files)})

      {:noreply, assign(socket, blocks: replace_block(socket.assigns.blocks, updated_block))}
    else
      {:noreply, socket}
    end
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
    upload_name =
      case to_string(socket.assigns.uploading_media_type) do
        "video" -> :video_upload
        "attachment" -> :attachment_upload
        _ -> :image_upload
      end

    socket =
      if socket.assigns.uploading_media_type do
        Enum.reduce(socket.assigns.uploads[upload_name].entries, socket, fn entry, acc ->
          cancel_upload(acc, upload_name, entry.ref)
        end)
      else
        socket
      end

    {:noreply, assign(socket, uploading_for_block: nil, uploading_media_type: nil)}
  end

  def handle_event("cancel-upload", %{"ref" => ref}, socket) do
    upload_name =
      case to_string(socket.assigns.uploading_media_type) do
        "video" -> :video_upload
        "attachment" -> :attachment_upload
        _ -> :image_upload
      end

    {:noreply, cancel_upload(socket, upload_name, ref)}
  end

  def handle_event("save_media", _params, socket) do
    block_id = socket.assigns.uploading_for_block
    block = Enum.find(socket.assigns.blocks, &(&1.id == block_id))
    process_media_save(socket, block)
  end

  # --- LIBRARY INTEGRATION EVENTS ---
  def handle_event("open_library_picker", _, socket) do
    {:ok, {blocks, _meta}} = Content.list_library_blocks(%{}, socket.assigns.current_user.id)

    {:noreply,
     assign(socket, library_picker_open: true, library_blocks: blocks, library_search: "")}
  end

  def handle_event("close_library_picker", _, socket) do
    {:noreply, assign(socket, library_picker_open: false)}
  end

  def handle_event("search_library", %{"search" => search}, socket) do
    flop_params =
      if search != "",
        do: %{
          "filters" => %{"0" => %{"field" => "title", "op" => "ilike_and", "value" => search}}
        },
        else: %{}

    {:ok, {blocks, _meta}} =
      Content.list_library_blocks(flop_params, socket.assigns.current_user.id)

    {:noreply, assign(socket, library_blocks: blocks, library_search: search)}
  end

  def handle_event("insert_from_library", %{"id" => lib_id}, socket) do
    {:ok, lib_block} = Content.get_library_block(lib_id)

    attrs = %{
      "type" => Atom.to_string(lib_block.type),
      "content" => lib_block.content,
      "section_id" => socket.assigns.active_section_id
    }

    case Content.create_block(attrs) do
      {:ok, block} ->
        updated_blocks = socket.assigns.blocks ++ [block]

        {:noreply,
         socket
         |> assign(blocks: updated_blocks, active_block_id: block.id, library_picker_open: false)
         |> put_flash(:info, gettext("Block inserted from library!"))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to insert block"))}
    end
  end

  def handle_event("open_save_library_modal", %{"id" => id}, socket) do
    block = Enum.find(socket.assigns.blocks, &(&1.id == id))
    {:noreply, assign(socket, saving_block_to_library: block)}
  end

  def handle_event("cancel_save_library", _, socket) do
    {:noreply, assign(socket, saving_block_to_library: nil)}
  end

  def handle_event("save_to_library", %{"title" => title, "tags_string" => tags_str}, socket) do
    block = socket.assigns.saving_block_to_library
    content_map = normalize_content(block.content || %{})

    tags =
      tags_str
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    attrs = %{
      "title" => title,
      "type" => Atom.to_string(block.type),
      "content" => content_map,
      "tags" => tags,
      "owner_id" => socket.assigns.current_user.id
    }

    case Content.create_library_block(attrs) do
      {:ok, _lib_block} ->
        {:noreply,
         socket
         |> assign(saving_block_to_library: nil)
         |> put_flash(:info, gettext("Saved to library!"))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to save to library"))}
    end
  end

  @impl true
  def render(assigns) do
    active_section = find_section_in_tree(assigns.sections, assigns.active_section_id)
    active_block = Enum.find(assigns.blocks, &(&1.id == assigns.active_block_id))

    assigns =
      assigns
      |> assign(
        active_section: active_section,
        active_block: active_block,
        image_types_str: @image_types_str,
        video_types_str: @video_types_str,
        attachment_types_str: @attachment_types_str
      )

    ~H"""
    <div class="hidden lg:flex fixed inset-0 pt-16 lg:pt-0 z-50 bg-base-200">
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
            server_now={@server_now}
          />
        </div>
      </div>

      <.modal
        :if={@uploading_for_block}
        id="media-upload-modal"
        show={true}
        title={gettext("Upload Media")}
        on_cancel={JS.push("cancel_upload")}
      >
        <% active_upload =
          case to_string(@uploading_media_type) do
            "video" -> @uploads.video_upload
            "attachment" -> @uploads.attachment_upload
            _ -> @uploads.image_upload
          end %>
        <% has_entries = active_upload.entries != [] %>
        <% is_uploading =
          Enum.any?(
            active_upload.entries,
            &(&1.progress > 0 and &1.progress < 100 and upload_errors(active_upload, &1) == [])
          ) %>

        <.form for={nil} id="upload-form" phx-submit="save_media" phx-change="validate_media">
          <div
            class={[
              "relative border-2 border-dashed border-base-300 rounded-lg hover:border-primary/50 hover:bg-base-200/50 transition-all",
              has_entries && "hidden"
            ]}
            phx-drop-target={active_upload.ref}
          >
            <label class="cursor-pointer flex flex-col items-center justify-center p-8 w-full h-full">
              <.live_file_input upload={active_upload} class="sr-only" />
              <.icon name="hero-cloud-arrow-up" class="size-10 text-primary mb-2" />
              <span class="font-bold text-center">{gettext("Click or drag file here")}</span>
              <span class="text-xs text-base-content/50 mt-1">
                <%= case to_string(@uploading_media_type) do %>
                  <% "video" -> %>
                    {@video_types_str} (500MB)
                  <% "attachment" -> %>
                    {@attachment_types_str} (50MB, max 10)
                  <% _ -> %>
                    {@image_types_str} (10MB)
                <% end %>
              </span>
            </label>
          </div>
        </.form>

        <div
          :for={entry <- active_upload.entries}
          class="mt-4 flex flex-col gap-2 p-4 bg-base-200 rounded-xl border border-base-300"
        >
          <div class="flex items-center justify-between text-sm">
            <div class="flex items-center gap-2 truncate font-medium">
              <.icon
                name={
                  if to_string(@uploading_media_type) == "video",
                    do: "hero-video-camera",
                    else: "hero-photo"
                }
                class="size-5 text-base-content/50 shrink-0"
              />
              <span class="truncate">{entry.client_name}</span>
            </div>

            <div class="flex items-center gap-3 shrink-0">
              <span class="text-base-content/50 font-bold">{entry.progress}%</span>
              <button
                type="button"
                phx-click="cancel-upload"
                phx-value-ref={entry.ref}
                class="btn btn-ghost btn-xs btn-circle text-error hover:bg-error/20"
                title={gettext("Remove file")}
              >
                <.icon name="hero-x-mark" class="size-4" />
              </button>
            </div>
          </div>

          <progress
            class={[
              "progress w-full",
              upload_errors(active_upload, entry) != [] && "progress-error",
              upload_errors(active_upload, entry) == [] && "progress-primary"
            ]}
            value={entry.progress}
            max="100"
          >
          </progress>

          <div
            :for={err <- upload_errors(active_upload, entry)}
            class="text-error text-xs font-bold flex items-center gap-1 mt-1"
          >
            <.icon name="hero-exclamation-circle" class="size-4 shrink-0" />
            {upload_error_to_string(err)}
          </div>
        </div>

        <div class="modal-action mt-6">
          <.button type="button" class="btn btn-ghost" phx-click="cancel_upload">
            {gettext("Cancel")}
          </.button>

          <.button
            type="submit"
            form="upload-form"
            class="btn btn-primary"
            disabled={
              not has_entries or is_uploading or
                Enum.any?(active_upload.entries, &(upload_errors(active_upload, &1) != []))
            }
          >
            {if is_uploading, do: gettext("Uploading..."), else: gettext("Upload")}
          </.button>
        </div>
      </.modal>

      <.modal
        :if={@moving_section_id}
        id="move-section-modal"
        show={true}
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
        :if={@quick_nav_open}
        id="quick-nav-modal"
        show={true}
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
        show={true}
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
        show={true}
        title={gettext("Delete Block")}
        description={gettext("Remove this content block from the lesson?")}
        confirm_label={gettext("Delete")}
        danger={true}
        on_cancel={JS.push("cancel_block_delete")}
        on_confirm={JS.push("confirm_delete_block")}
      />

      <.slide_over
        id="library-picker-slideover"
        show={@library_picker_open}
        title={gettext("Library")}
        on_close={JS.push("close_library_picker")}
      >
        <div class="flex flex-col h-full">
          <div class="p-6 border-b border-base-200 shrink-0">
            <.form
              for={nil}
              id="library-search-form"
              phx-change="search_library"
              phx-submit="search_library"
            >
              <.input
                type="text"
                name="search"
                value={@library_search}
                placeholder={gettext("Search templates...")}
                phx-debounce="300"
              />
            </.form>
          </div>
          <div class="flex-1 overflow-y-auto p-6 space-y-4">
            <div
              :for={lib_block <- @library_blocks}
              class="p-5 bg-base-100 border border-base-300 rounded-xl hover:border-primary/50 transition-colors flex flex-col gap-3 shadow-sm"
            >
              <div class="flex justify-between items-start">
                <h4 class="font-bold text-lg leading-tight">{lib_block.title}</h4>
                <span class="badge badge-sm badge-outline uppercase tracking-widest text-[10px] font-black shrink-0">
                  {lib_block.type}
                </span>
              </div>
              <div class="flex flex-wrap gap-1">
                <span :for={tag <- lib_block.tags || []} class="badge badge-xs badge-neutral">
                  {tag}
                </span>
              </div>
              <div class="mt-2 text-right border-t border-base-200 pt-3">
                <.button
                  type="button"
                  phx-click="insert_from_library"
                  phx-value-id={lib_block.id}
                  class="btn btn-sm btn-primary w-full sm:w-auto"
                >
                  {gettext("Insert Block")}
                </.button>
              </div>
            </div>
            <div :if={@library_blocks == []} class="text-center py-10 opacity-50 font-medium">
              {gettext("No templates found.")}
            </div>
          </div>
        </div>
      </.slide_over>

      <.modal
        :if={@saving_block_to_library}
        id="save-library-modal"
        show={true}
        title={gettext("Save to Library")}
        on_cancel={JS.push("cancel_save_library")}
      >
        <.form for={nil} phx-submit="save_to_library" class="space-y-4">
          <.input type="text" name="title" value="" label={gettext("Template Title")} required />
          <.input
            type="text"
            name="tags_string"
            value=""
            label={gettext("Tags (comma separated)")}
            placeholder="elixir, hard, quiz"
          />
          <div class="modal-action">
            <.button type="button" class="btn btn-ghost" phx-click="cancel_save_library">
              {gettext("Cancel")}
            </.button>
            <.button type="submit" class="btn btn-primary">{gettext("Save Template")}</.button>
          </div>
        </.form>
      </.modal>
    </div>

    <div class="flex lg:hidden h-screen w-full items-center justify-center bg-base-200 p-8 text-center relative z-50">
      <div class="max-w-md space-y-4">
        <.icon name="hero-computer-desktop" class="size-20 text-primary mx-auto opacity-50 mb-6" />
        <h2 class="text-3xl font-black font-display tracking-tight text-base-content">
          {gettext("Screen too small")}
        </h2>
        <p class="text-base-content/60 text-lg mb-8">
          {gettext(
            "The Course Builder requires a desktop or tablet screen to work comfortably. Please open this page on a larger device."
          )}
        </p>
        <.link navigate={~p"/studio/courses"} class="btn btn-primary btn-lg mt-4 w-full">
          {gettext("Back to Courses")}
        </.link>
      </div>
    </div>
    """
  end

  # --- PRIVATE HELPERS ---

  @doc false
  defp normalize_content(%{__struct__: _} = struct) do
    struct |> Map.from_struct() |> normalize_content()
  end

  defp normalize_content(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), normalize_content(v)} end)
  end

  defp normalize_content(list) when is_list(list) do
    Enum.map(list, &normalize_content/1)
  end

  defp normalize_content(value), do: value

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

  @doc false
  defp presign_upload(entry, socket) do
    course_id = socket.assigns.course.id

    case Content.prepare_media_upload(course_id, entry.client_name) do
      {:ok, meta} ->
        {:ok, meta, socket}

      {:error, _} ->
        {:error, dgettext("errors", "Could not generate upload URL")}
    end
  end

  @doc false
  defp process_media_save(socket, nil) do
    {:noreply, assign(socket, uploading_for_block: nil, uploading_media_type: nil)}
  end

  defp process_media_save(socket, block) do
    user_id = socket.assigns.current_user.id
    media_type = to_string(socket.assigns.uploading_media_type)

    upload_name =
      case to_string(socket.assigns.uploading_media_type) do
        "video" -> :video_upload
        "attachment" -> :attachment_upload
        _ -> :image_upload
      end

    upload_results =
      consume_uploaded_entries(socket, upload_name, fn meta, entry ->
        file_info = %{
          name: entry.client_name,
          type: entry.client_type,
          size: entry.client_size
        }

        save_consumed_media(media_type, block, user_id, meta, file_info)
      end)

    apply_upload_results(socket, media_type, block, upload_results)
  end

  defp save_consumed_media("tiptap_image", _block, user_id, meta, file_info) do
    file_attrs = %{
      "bucket" => meta.bucket,
      "key" => meta.key,
      "original_name" => file_info.name,
      "mime_type" => file_info.type,
      "size" => file_info.size,
      "context" => "course_material",
      "owner_id" => user_id
    }

    case Athena.Media.create_file(file_attrs) do
      {:ok, _file} -> {:ok, {:ok, %{url: meta.url_for_saved_entry, type: "tiptap_image"}}}
      {:error, err} -> {:ok, {:error, err}}
    end
  end

  defp save_consumed_media("attachment", _block, user_id, meta, file_info) do
    file_attrs = %{
      "bucket" => meta.bucket,
      "key" => meta.key,
      "original_name" => file_info.name,
      "mime_type" => file_info.type,
      "size" => file_info.size,
      "context" => "course_material",
      "owner_id" => user_id
    }

    case Athena.Media.create_file(file_attrs) do
      {:ok, _file} ->
        file_data = %{
          "url" => meta.url_for_saved_entry,
          "name" => file_info.name,
          "size" => file_info.size,
          "mime" => file_info.type
        }

        {:ok, {:ok, file_data}}

      {:error, err} ->
        {:ok, {:error, err}}
    end
  end

  defp save_consumed_media(_media_type, block, user_id, meta, file_info) do
    case Content.attach_media_to_block(block, user_id, meta, file_info) do
      {:ok, updated_block} -> {:ok, {:ok, updated_block}}
      {:error, err} -> {:ok, {:error, err}}
    end
  end

  @doc false
  defp apply_upload_results(socket, "tiptap_image", _block, [
         {:ok, %{url: url, type: "tiptap_image"}} | _
       ]) do
    block_id = socket.assigns.uploading_for_block

    {:noreply,
     socket
     |> assign(uploading_for_block: nil, uploading_media_type: nil)
     |> push_event("insert_media", %{block_id: block_id, url: url, type: "tiptap_image"})
     |> put_flash(:info, gettext("Image inserted into text!"))}
  end

  defp apply_upload_results(socket, "attachment", block, results) do
    new_files =
      Enum.reduce(results, [], fn
        {:ok, file_map}, acc -> [file_map | acc]
        _, acc -> acc
      end)
      |> Enum.reverse()

    if new_files != [] do
      content_map = normalize_content(block.content || %{})
      existing_files = Map.get(content_map, "files", [])
      new_content = Map.put(content_map, "files", existing_files ++ new_files)

      {:ok, updated_block} = Content.update_block(block, %{"content" => new_content})

      {:noreply,
       socket
       |> assign(
         blocks: replace_block(socket.assigns.blocks, updated_block),
         uploading_for_block: nil,
         uploading_media_type: nil
       )
       |> put_flash(:info, gettext("Files attached successfully!"))}
    else
      {:noreply,
       socket
       |> assign(uploading_for_block: nil, uploading_media_type: nil)
       |> put_flash(:error, gettext("Error saving attachments."))}
    end
  end

  defp apply_upload_results(socket, _media_type, _block, [
         {:ok, %Block{} = updated_block} | _
       ]) do
    {:noreply,
     socket
     |> assign(
       blocks: replace_block(socket.assigns.blocks, updated_block),
       uploading_for_block: nil,
       uploading_media_type: nil
     )
     |> put_flash(:info, gettext("Media uploaded successfully!"))}
  end

  defp apply_upload_results(socket, _media_type, _block, _errors) do
    {:noreply,
     socket
     |> assign(uploading_for_block: nil, uploading_media_type: nil)
     |> put_flash(:error, dgettext("errors", "Error saving media data."))}
  end

  @doc false
  defp upload_error_to_string(:too_large), do: gettext("File is too large")

  defp upload_error_to_string(:not_accepted),
    do: gettext("You have selected an unacceptable file type")

  defp upload_error_to_string(:external_client_failure),
    do: gettext("Upload failed. Check your internet connection or cloud storage settings.")

  defp upload_error_to_string(_), do: gettext("An unknown error occurred")

  defp create_and_assign_block(socket, attrs, error_msg \\ gettext("Failed to create block")) do
    case Content.create_block(attrs) do
      {:ok, block} ->
        updated_blocks = socket.assigns.blocks ++ [block]
        {:noreply, assign(socket, blocks: updated_blocks, active_block_id: block.id)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, error_msg)}
    end
  end

  defp parse_quiz_options(opts, correct_id) do
    opts
    |> Enum.sort_by(fn {k, _} -> String.to_integer(k) end)
    |> Enum.map(fn {_, v} ->
      is_correct =
        if correct_id do
          v["id"] == correct_id
        else
          v["is_correct"] in ["true", true]
        end

      %{v | "is_correct" => is_correct}
    end)
  end

  defp apply_quiz_meta_overrides(original_content, overrides) do
    overrides
    |> apply_exact_match_default(original_content)
    |> apply_single_choice_fix(original_content)
    |> apply_case_sensitive_fix()
  end

  defp apply_exact_match_default(overrides, original) do
    if overrides["question_type"] == "exact_match" and original["correct_answer"] in [nil, ""] do
      Map.put(overrides, "correct_answer", "flag{...}")
    else
      overrides
    end
  end

  defp apply_single_choice_fix(
         %{"question_type" => "single"} = overrides,
         %{"question_type" => "multiple"} = original
       ) do
    opts = original["options"] || []

    {new_opts, _} = Enum.map_reduce(opts, false, &enforce_single_correct/2)

    Map.put(overrides, "options", new_opts)
  end

  defp apply_single_choice_fix(overrides, _original), do: overrides

  defp enforce_single_correct(opt, found_correct) do
    is_correct = opt["is_correct"] in ["true", true]

    if is_correct and not found_correct do
      {%{opt | "is_correct" => true}, true}
    else
      {%{opt | "is_correct" => false}, found_correct}
    end
  end

  defp apply_case_sensitive_fix(overrides) do
    if Map.has_key?(overrides, "case_sensitive") do
      Map.put(overrides, "case_sensitive", overrides["case_sensitive"] in ["true", true])
    else
      overrides
    end
  end
end
