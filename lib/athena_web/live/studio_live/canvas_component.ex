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
            class="relative group"
          >
            <div class="absolute -left-10 top-1/2 -translate-y-1/2 p-2 opacity-0 group-hover:opacity-50 hover:opacity-100 cursor-grab drag-handle transition-opacity hidden sm:block">
              <.icon name="hero-bars-3" class="size-5" />
            </div>

            <div phx-click="select_block" phx-value-id={block.id}>
              <.content_block block={block} mode={:edit} active={@active_block_id == block.id} />
            </div>

            <%= if @active_block_id == block.id do %>
              <.block_editor block={block} />
            <% end %>
          </div>
        </div>

        <div class="sticky bottom-8 mt-auto flex justify-center z-30 pointer-events-none">
          <div class="dropdown dropdown-top dropdown-center pointer-events-auto">
            <div
              tabindex="0"
              role="button"
              class="btn btn-primary btn-circle shadow-2xl size-14 group"
            >
              <.icon name="hero-plus" class="size-8" />
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
                  onclick="document.activeElement.blur()"
                  class="btn btn-ghost justify-start font-medium gap-3 h-12"
                >
                  <.icon name="hero-document-text" class="size-5 opacity-50" /> {gettext("Text Block")}
                </.button>
              </li>
              <li>
                <.button
                  phx-click="add_code_block"
                  onclick="document.activeElement.blur()"
                  class="btn btn-ghost justify-start font-medium gap-3 h-12"
                >
                  <.icon name="hero-code-bracket" class="size-5 opacity-50" /> {gettext(
                    "Code Sandbox"
                  )}
                </.button>
              </li>
              <li>
                <.button
                  phx-click="add_quiz_question_block"
                  onclick="document.activeElement.blur()"
                  class="btn btn-ghost justify-start font-medium gap-3 h-12"
                >
                  <.icon name="hero-question-mark-circle" class="size-5 opacity-50" /> {gettext(
                    "Quiz Question"
                  )}
                </.button>
              </li>
              <li>
                <.button
                  phx-click="add_quiz_exam_block"
                  onclick="document.activeElement.blur()"
                  class="btn btn-ghost justify-start font-medium gap-3 h-12"
                >
                  <.icon name="hero-academic-cap" class="size-5 opacity-50" /> {gettext("Quiz Exam")}
                </.button>
              </li>
              <li>
                <.button
                  phx-click="add_image_block"
                  onclick="document.activeElement.blur()"
                  class="btn btn-ghost justify-start font-medium gap-3 h-12"
                >
                  <.icon name="hero-photo" class="size-5 opacity-50" /> {gettext("Image")}
                </.button>
              </li>
              <li>
                <.button
                  phx-click="add_video_block"
                  onclick="document.activeElement.blur()"
                  class="btn btn-ghost justify-start font-medium gap-3 h-12"
                >
                  <.icon name="hero-video-camera" class="size-5 opacity-50" /> {gettext("Video")}
                </.button>
              </li>
              <li>
                <.button
                  phx-click="add_attachment_block"
                  onclick="document.activeElement.blur()"
                  class="btn btn-ghost justify-start font-medium gap-3 h-12"
                >
                  <.icon name="hero-paper-clip" class="size-5 opacity-50" /> {gettext(
                    "Files & Materials"
                  )}
                </.button>
              </li>
              <div class="divider my-1"></div>
              <li>
                <.button
                  phx-click="open_library_picker"
                  onclick="document.activeElement.blur()"
                  class="btn btn-ghost justify-start font-bold text-primary gap-3 h-12"
                >
                  <.icon name="hero-bookmark-square" class="size-5" /> {gettext("Add from Library")}
                </.button>
              </li>
            </ul>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
