defmodule AthenaWeb.StudioLive.Builder.CanvasComponent do
  @moduledoc """
  LiveComponent for rendering the main canvas with blocks.
  Uses universal content_block for rendering, and overlays contextual editors 
  when a block is selected.
  """
  use AthenaWeb, :live_component
  import AthenaWeb.BlockComponents

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex-1 flex flex-col relative">
      <div :if={@active_section_id == nil} class="flex-1 flex items-center justify-center">
        <p class="text-base-content/50 font-medium">
          {gettext("Select a section from the sidebar to view its blocks.")}
        </p>
      </div>

      <div :if={@active_section_id != nil} class="flex-1 flex flex-col pb-32">
        <div
          id="canvas-blocks-list"
          phx-hook="Sortable"
          data-event-name="reorder_block"
          class="flex-1 flex flex-col gap-2"
        >
          <div
            :for={block <- @blocks}
            id={"block-wrapper-#{block.id}"}
            data-id={block.id}
            class="relative group flex flex-col"
            phx-click-away={if @active_block_id == block.id, do: "deselect_block"}
          >
            <div class="absolute -left-8 top-0 flex flex-col items-center gap-1 opacity-0 group-hover:opacity-50 hover:opacity-100! transition-opacity sm:flex z-10">
              <.button
                phx-click="move_block_up"
                phx-value-id={block.id}
                class="p-1 hover:text-primary transition-colors cursor-pointer"
                title={gettext("Move Up")}
              >
                <.icon name="hero-chevron-up" class="size-5" />
              </.button>
              <div
                class="cursor-grab drag-handle p-1 hover:text-primary transition-colors"
                title={gettext("Drag to Reorder")}
              >
                <.icon name="hero-bars-3" class="size-5" />
              </div>
              <.button
                phx-click="move_block_down"
                phx-value-id={block.id}
                class="p-1 hover:text-primary transition-colors cursor-pointer"
                title={gettext("Move Down")}
              >
                <.icon name="hero-chevron-down" class="size-5" />
              </.button>
            </div>

            <div
              phx-click="select_block"
              phx-value-id={block.id}
              class={[
                "relative transition-all duration-300",
                @active_block_id != block.id && block.type == :text && "max-h-48 overflow-hidden"
              ]}
            >
              <.content_block block={block} mode={:edit} active={@active_block_id == block.id} />

              <div
                :if={@active_block_id != block.id && block.type == :text}
                class="absolute bottom-0 left-0 right-0 h-16 bg-linear-to-t from-base-100 to-transparent pointer-events-none rounded-b-sm"
              >
              </div>
            </div>

            <%= if @active_block_id == block.id do %>
              <div class="mt-2">
                <.block_editor block={block} />
              </div>
            <% end %>

            <%= if @active_block_id == block.id do %>
              <div class="relative z-40 my-4 flex justify-center animate-in fade-in zoom-in duration-200">
                <.add_content_dropdown after_id={block.id} direction="dropdown-bottom" />
              </div>
            <% end %>
          </div>
        </div>

        <div class="mt-12 flex justify-center z-30 opacity-50 hover:opacity-100 transition-opacity">
          <.add_content_dropdown direction="dropdown-top" />
        </div>
      </div>
    </div>
    """
  end

  @doc false
  attr :direction, :string, default: "dropdown-bottom"
  attr :after_id, :string, default: nil

  defp add_content_dropdown(assigns) do
    ~H"""
    <div class={["dropdown dropdown-center pointer-events-auto", @direction]}>
      <div
        tabindex="0"
        role="button"
        class="btn btn-primary btn-circle shadow-lg size-12 group hover:scale-110 transition-transform"
      >
        <.icon name="hero-plus" class="size-6" />
      </div>
      <ul
        tabindex="0"
        class="dropdown-content z-50 menu p-2 shadow-2xl bg-base-100 border border-base-300 rounded-xl w-64 my-2 animate-in fade-in duration-200"
      >
        <li class="menu-title text-xs uppercase tracking-widest opacity-50 px-4 py-2">
          {gettext("Add Content")}
        </li>
        <li>
          <.button
            phx-click="add_text_block"
            phx-value-after_id={@after_id}
            onclick="document.activeElement.blur()"
            class="btn btn-ghost justify-start font-medium gap-3 h-10"
          >
            <.icon name="hero-document-text" class="size-5 opacity-50" /> {gettext("Text Block")}
          </.button>
        </li>
        <li>
          <.button
            phx-click="add_code_block"
            phx-value-after_id={@after_id}
            onclick="document.activeElement.blur()"
            class="btn btn-ghost justify-start font-medium gap-3 h-10"
          >
            <.icon name="hero-code-bracket" class="size-5 opacity-50" /> {gettext("Code Sandbox")}
          </.button>
        </li>
        <li>
          <.button
            phx-click="add_quiz_question_block"
            phx-value-after_id={@after_id}
            onclick="document.activeElement.blur()"
            class="btn btn-ghost justify-start font-medium gap-3 h-10"
          >
            <.icon name="hero-question-mark-circle" class="size-5 opacity-50" /> {gettext(
              "Quiz Question"
            )}
          </.button>
        </li>
        <li>
          <.button
            phx-click="add_quiz_exam_block"
            phx-value-after_id={@after_id}
            onclick="document.activeElement.blur()"
            class="btn btn-ghost justify-start font-medium gap-3 h-10"
          >
            <.icon name="hero-academic-cap" class="size-5 opacity-50" /> {gettext("Quiz Exam")}
          </.button>
        </li>
        <li>
          <.button
            phx-click="add_image_block"
            phx-value-after_id={@after_id}
            onclick="document.activeElement.blur()"
            class="btn btn-ghost justify-start font-medium gap-3 h-10"
          >
            <.icon name="hero-photo" class="size-5 opacity-50" /> {gettext("Image")}
          </.button>
        </li>
        <li>
          <.button
            phx-click="add_video_block"
            phx-value-after_id={@after_id}
            onclick="document.activeElement.blur()"
            class="btn btn-ghost justify-start font-medium gap-3 h-10"
          >
            <.icon name="hero-video-camera" class="size-5 opacity-50" /> {gettext("Video")}
          </.button>
        </li>
        <li>
          <.button
            phx-click="add_attachment_block"
            phx-value-after_id={@after_id}
            onclick="document.activeElement.blur()"
            class="btn btn-ghost justify-start font-medium gap-3 h-10"
          >
            <.icon name="hero-paper-clip" class="size-5 opacity-50" /> {gettext("Files & Materials")}
          </.button>
        </li>
        <div class="divider my-0.5"></div>
        <li>
          <.button
            phx-click="open_library_picker"
            phx-value-after_id={@after_id}
            onclick="document.activeElement.blur()"
            class="btn btn-ghost justify-start font-bold text-primary gap-3 h-10"
          >
            <.icon name="hero-bookmark-square" class="size-5" /> {gettext("Add from Library")}
          </.button>
        </li>
      </ul>
    </div>
    """
  end
end
