defmodule AthenaWeb.StudioLive.Builder.CanvasComponent do
  @moduledoc """
  LiveComponent for rendering the main canvas with blocks.

  This component acts as the primary workspace for the course builder. 
  It displays the list of blocks for the currently selected section, handles 
  the drag-and-drop reordering interface via Sortable.js, renders the TipTap 
  editor for text blocks, and provides floating controls for adding new blocks.
  """
  use AthenaWeb, :live_component

  @doc """
  Renders the canvas UI based on the selected section and its blocks.

  Displays a prompt if no section is active. If a section is active, iterates 
  through the `@blocks` assign and renders the appropriate interactive UI 
  for each block type (:text, :code, etc.).
  """
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex-1 flex flex-col relative">
      <div :if={@active_section_id == nil} class="flex-1 flex items-center justify-center">
        <p class="text-base-content/50 font-medium">
          {gettext("Select a section from the sidebar to view its blocks.")}
        </p>
      </div>

      <div :if={@active_section_id != nil} class="flex-1 flex flex-col">
        <div
          id="canvas-blocks-list"
          phx-hook="Sortable"
          data-event-name="reorder_block"
          class="flex-1 space-y-4"
        >
          <div
            :for={block <- @blocks}
            id={"block-#{block.id}"}
            data-id={block.id}
            phx-click="select_block"
            phx-value-id={block.id}
            class={[
              "group relative rounded-xl transition-all cursor-pointer bg-base-100 shadow-sm ring-1",
              @active_block_id == block.id && "ring-primary shadow-md",
              @active_block_id != block.id && "ring-base-200 hover:ring-base-300"
            ]}
          >
            <div class="absolute -left-10 top-1/2 -translate-y-1/2 p-2 opacity-0 group-hover:opacity-50 hover:opacity-100! cursor-grab drag-handle transition-opacity hidden sm:block">
              <.icon name="hero-bars-3" class="size-5" />
            </div>

            <div class="p-4 sm:px-6 py-4">
              <%= cond do %>
                <% block.type == :text -> %>
                  <div
                    id={"tiptap-#{block.id}"}
                    phx-hook="TiptapEditor"
                    data-id={block.id}
                    phx-update="ignore"
                    data-content={Jason.encode!(block.content)}
                    class="min-h-[100px]"
                  >
                  </div>
                <% block.type == :image -> %>
                  <%= if block.content["url"] do %>
                    <img
                      src={block.content["url"]}
                      alt={block.content["alt"]}
                      class="rounded-lg w-full object-cover"
                    />
                  <% else %>
                    <button
                      type="button"
                      phx-click="request_media_upload"
                      phx-value-block_id={block.id}
                      phx-value-media_type="image"
                      class="w-full text-center p-10 bg-base-200/50 hover:bg-base-200 rounded-lg border-2 border-dashed border-base-300 hover:border-primary/50 transition-colors flex flex-col items-center gap-3 group"
                    >
                      <.icon
                        name="hero-cloud-arrow-up"
                        class="size-10 text-base-content/20 group-hover:text-primary/50 transition-colors"
                      />
                      <span class="text-sm font-medium text-base-content/50 group-hover:text-primary transition-colors">
                        {gettext("Click to upload image")}
                      </span>
                    </button>
                  <% end %>
                <% block.type == :video -> %>
                  <%= if block.content["url"] do %>
                    <video
                      src={block.content["url"]}
                      poster={block.content["poster_url"]}
                      controls={block.content["controls"] not in [false, "false"]}
                      class="rounded-lg w-full bg-black aspect-video"
                    />
                  <% else %>
                    <button
                      type="button"
                      phx-click="request_media_upload"
                      phx-value-block_id={block.id}
                      phx-value-media_type="video"
                      class="w-full text-center p-10 bg-base-200/50 hover:bg-base-200 rounded-lg border-2 border-dashed border-base-300 hover:border-primary/50 transition-colors flex flex-col items-center gap-3 group"
                    >
                      <.icon
                        name="hero-cloud-arrow-up"
                        class="size-10 text-base-content/20 group-hover:text-primary/50 transition-colors"
                      />
                      <span class="text-sm font-medium text-base-content/50 group-hover:text-primary transition-colors">
                        {gettext("Click to upload video")}
                      </span>
                    </button>
                  <% end %>
                <% block.type == :attachment -> %>
                  <div
                    id={"tiptap-#{block.id}"}
                    phx-hook="TiptapEditor"
                    data-id={block.id}
                    phx-update="ignore"
                    data-content={Jason.encode!(block.content["description"] || %{})}
                    class="min-h-[100px] mb-6"
                  >
                  </div>

                  <div class="space-y-2 mb-4">
                    <div
                      :for={file <- block.content["files"] || []}
                      class="flex items-center gap-3 p-3 bg-base-200/50 rounded-lg border border-base-300 hover:border-primary/30 transition-colors"
                    >
                      <div class="p-2 bg-base-100 rounded shadow-sm text-primary shrink-0">
                        <.icon name="hero-document" class="size-5" />
                      </div>
                      <div class="flex-1 min-w-0">
                        <div class="text-sm font-bold truncate text-base-content/80">
                          {file["name"]}
                        </div>
                        <div class="text-xs text-base-content/50">{format_bytes(file["size"])}</div>
                      </div>
                      <.button
                        type="button"
                        phx-click="delete_attachment"
                        phx-value-block_id={block.id}
                        phx-value-url={file["url"]}
                        class="btn-ghost btn-sm btn-square text-error hover:bg-error/20"
                        title={gettext("Remove file")}
                      >
                        <.icon name="hero-trash" class="size-4" />
                      </.button>
                    </div>
                  </div>

                  <button
                    type="button"
                    phx-click="request_media_upload"
                    phx-value-block_id={block.id}
                    phx-value-media_type="attachment"
                    class="w-full text-center py-4 bg-base-100 hover:bg-base-200 rounded-lg border-2 border-dashed border-base-300 hover:border-primary/50 transition-colors flex items-center justify-center gap-2 group text-sm font-medium text-base-content/50"
                  >
                    <.icon
                      name="hero-plus-circle"
                      class="size-5 group-hover:text-primary transition-colors"
                    />
                    <span class="group-hover:text-primary transition-colors">
                      {gettext("Add Files")}
                    </span>
                  </button>
                <% true -> %>
                  <div class="text-sm text-base-content/50 italic p-4 ring-1 ring-dashed ring-base-300 rounded select-none bg-base-200/50">
                    <div class="flex items-center gap-2 mb-1">
                      <.icon name="hero-code-bracket" class="size-4" />
                      <span class="font-bold text-xs uppercase">{block.type}</span>
                    </div>
                    {gettext("Preview block content")}
                  </div>
              <% end %>
            </div>
          </div>

          <div
            :if={@blocks == []}
            class="text-center py-20 border-2 border-dashed border-base-300 rounded-lg"
          >
            <p class="text-base-content/50 mb-4">{gettext("This section is empty.")}</p>
          </div>
        </div>

        <div class="sticky bottom-8 mt-auto flex justify-center z-30 pointer-events-none">
          <div class="dropdown dropdown-top dropdown-center pointer-events-auto">
            <div
              tabindex="0"
              role="button"
              class="btn btn-primary btn-circle shadow-2xl size-14 group"
            >
              <.icon name="hero-plus" class="size-8 " />
            </div>
            <ul
              tabindex="0"
              class="dropdown-content z-1 menu p-2 shadow-2xl bg-base-100 border border-base-200 rounded-2xl w-100 mb-4 animate-in slide-in-from-bottom-2 duration-200"
            >
              <li class="menu-title text-xs uppercase tracking-widest opacity-50 px-4 py-2">
                {gettext("Add Content")}
              </li>
              <li>
                <.button
                  phx-click="add_text_block"
                  class="btn btn-ghost justify-start font-medium gap-3 h-12"
                >
                  <.icon name="hero-document-text" class="size-5 opacity-50" />
                  {gettext("Text Block")}
                </.button>
              </li>
              <li>
                <.button
                  phx-click="add_code_block"
                  class="btn btn-ghost justify-start font-medium gap-3 h-12"
                >
                  <.icon name="hero-code-bracket" class="size-5 opacity-50" />
                  {gettext("Code Sandbox")}
                </.button>
              </li>
              <li>
                <.button
                  phx-click="add_image_block"
                  class="btn btn-ghost justify-start font-medium gap-3 h-12"
                >
                  <.icon name="hero-photo" class="size-5 opacity-50" />
                  {gettext("Image")}
                </.button>
              </li>
              <li>
                <.button
                  phx-click="add_video_block"
                  class="btn btn-ghost justify-start font-medium gap-3 h-12"
                >
                  <.icon name="hero-video-camera" class="size-5 opacity-50" />
                  {gettext("Video")}
                </.button>
              </li>
              <li>
                <.button
                  phx-click="add_attachment_block"
                  class="btn btn-ghost justify-start font-medium gap-3 h-12"
                >
                  <.icon name="hero-paper-clip" class="size-5 opacity-50" />
                  {gettext("Files & Materials")}
                </.button>
              </li>
            </ul>
          </div>
        </div>
      </div>
    </div>
    """
  end

  @doc false
  defp format_bytes(bytes) do
    cond do
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 1)} MB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024, 1)} KB"
      true -> "#{bytes} B"
    end
  end
end
