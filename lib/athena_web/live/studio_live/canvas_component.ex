defmodule AthenaWeb.StudioLive.Builder.CanvasComponent do
  @moduledoc """
  LiveComponent for rendering the main canvas with blocks.
  """
  use AthenaWeb, :live_component
  import AthenaWeb.BlockComponents

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex-1 flex flex-col relative">
      <div :if={@active_section_id == nil} class="flex-1 flex items-center justify-center">
        <p class="text-base-content/50 font-medium text-lg">
          {gettext("Select a section from the sidebar to view its blocks.")}
        </p>
      </div>

      <div :if={@active_section_id != nil} class="flex-1 flex flex-col">
        <div
          id="canvas-blocks-list"
          phx-hook={if @mode == :edit, do: "Sortable"}
          data-event-name="reorder_block"
          class="flex-1 flex flex-col gap-2"
        >
          <div
            :for={block <- @blocks}
            id={"block-wrapper-#{block.id}"}
            data-id={block.id}
            class="relative group flex flex-col"
          >
            <div
              :if={@mode == :edit}
              class="absolute -left-8 top-0 flex flex-col items-center gap-1 opacity-0 group-hover:opacity-50 hover:opacity-100! transition-opacity sm:flex z-10"
            >
              <.button
                phx-click="move_block_up"
                phx-value-id={block.id}
                class="p-1 hover:text-primary transition-colors cursor-pointer rounded-sm"
                title={gettext("Move Up")}
              >
                <.icon name="hero-chevron-up" class="size-5" />
              </.button>
              <div
                class="cursor-grab drag-handle p-1 hover:text-primary transition-colors rounded-sm"
                title={gettext("Drag to Reorder")}
              >
                <.icon name="hero-bars-3" class="size-5" />
              </div>
              <.button
                phx-click="move_block_down"
                phx-value-id={block.id}
                class="p-1 hover:text-primary transition-colors cursor-pointer rounded-sm"
                title={gettext("Move Down")}
              >
                <.icon name="hero-chevron-down" class="size-5" />
              </.button>
            </div>

            <div
              phx-click="select_block"
              phx-value-id={block.id}
              class={[
                "relative transition-all duration-300 rounded-sm",
                @active_block_id != block.id && block.type == :text && "max-h-48 overflow-hidden"
              ]}
            >
              <.content_block block={block} mode={@mode} active={@active_block_id == block.id} />

              <div
                :if={@active_block_id != block.id && block.type == :text}
                class="absolute bottom-0 left-0 right-0 h-16 bg-linear-to-t from-base-100 to-transparent pointer-events-none rounded-b-sm"
              >
              </div>
            </div>

            <%= if @mode == :edit and @active_block_id == block.id do %>
              <div class="mt-2 rounded-sm">
                <.block_editor block={block} />
              </div>
            <% end %>

            <%= if @mode == :edit and @active_block_id == block.id do %>
              <div class="relative z-40 mt-4 mb-8 flex justify-center animate-in fade-in zoom-in duration-200">
                <.add_content_panel variant="inline" after_id={block.id} />
              </div>
            <% end %>
          </div>
        </div>

        <div :if={@mode == :edit} class="mt-12 z-30">
          <.add_content_panel variant="bottom" />
        </div>
      </div>
    </div>
    """
  end

  @doc false
  # "inline" or "bottom"
  attr :variant, :string, required: true
  attr :after_id, :string, default: nil

  defp add_content_panel(%{variant: "bottom"} = assigns) do
    ~H"""
    <div class="mt-2 grid grid-cols-2 sm:grid-cols-4 gap-3 rounded-sm transition-colors">
      <.button
        phx-click="add_text_block"
        phx-value-after_id={@after_id}
        class="btn btn-ghost rounded-sm bg-base-100 shadow-sm border border-base-200 hover:border-primary hover:text-primary flex-col h-auto py-4 gap-2 font-bold"
      >
        <.icon name="hero-document-text" class="size-6 opacity-70" />
        <span>{gettext("Text")}</span>
      </.button>

      <.button
        phx-click="add_image_block"
        phx-value-after_id={@after_id}
        class="btn btn-ghost rounded-sm bg-base-100 shadow-sm border border-base-200 hover:border-primary hover:text-primary flex-col h-auto py-4 gap-2 font-bold"
      >
        <.icon name="hero-photo" class="size-6 opacity-70" />
        <span>{gettext("Image")}</span>
      </.button>

      <.button
        phx-click="add_video_block"
        phx-value-after_id={@after_id}
        class="btn btn-ghost rounded-sm bg-base-100 shadow-sm border border-base-200 hover:border-primary hover:text-primary flex-col h-auto py-4 gap-2 font-bold"
      >
        <.icon name="hero-video-camera" class="size-6 opacity-70" />
        <span>{gettext("Video")}</span>
      </.button>

      <.button
        phx-click="add_attachment_block"
        phx-value-after_id={@after_id}
        class="btn btn-ghost rounded-sm bg-base-100 shadow-sm border border-base-200 hover:border-primary hover:text-primary flex-col h-auto py-4 gap-2 font-bold"
      >
        <.icon name="hero-paper-clip" class="size-6 opacity-70" />
        <span>{gettext("Files")}</span>
      </.button>

      <.button
        phx-click="add_quiz_question_block"
        phx-value-after_id={@after_id}
        class="btn btn-ghost rounded-sm bg-base-100 shadow-sm border border-base-200 hover:border-primary hover:text-primary flex-col h-auto py-4 gap-2 font-bold"
      >
        <.icon name="hero-question-mark-circle" class="size-6 opacity-70" />
        <span>{gettext("Question")}</span>
      </.button>

      <.button
        phx-click="add_quiz_exam_block"
        phx-value-after_id={@after_id}
        class="btn btn-ghost rounded-sm bg-base-100 shadow-sm border border-base-200 hover:border-primary hover:text-primary flex-col h-auto py-4 gap-2 font-bold"
      >
        <.icon name="hero-academic-cap" class="size-6 opacity-70" />
        <span>{gettext("Exam")}</span>
      </.button>

      <.button
        phx-click="add_code_block"
        phx-value-after_id={@after_id}
        class="btn btn-ghost rounded-sm bg-base-100 shadow-sm border border-base-200 hover:border-primary hover:text-primary flex-col h-auto py-4 gap-2 font-bold"
      >
        <.icon name="hero-code-bracket" class="size-6 opacity-70" />
        <span>{gettext("Code")}</span>
      </.button>

      <.button
        phx-click="open_library_picker"
        phx-value-after_id={@after_id}
        class="btn rounded-sm btn-primary/10 text-primary hover:btn-primary shadow-sm border border-primary/20 flex-col h-auto py-4 gap-2 font-black"
      >
        <.icon name="hero-bookmark-square" class="size-6" />
        <span>{gettext("Library")}</span>
      </.button>
    </div>
    """
  end

  defp add_content_panel(%{variant: "inline"} = assigns) do
    ~H"""
    <div class="flex items-center gap-1 p-1.5 bg-base-100 border border-base-300 rounded-sm shadow-lg">
      <.button
        id={"inline-add-text-#{@after_id}"}
        phx-hook="TippyTooltip"
        data-tippy-content={gettext("Text")}
        phx-click="add_text_block"
        phx-value-after_id={@after_id}
        class="btn btn-sm btn-ghost btn-square rounded-sm hover:text-primary hover:bg-primary/10"
      >
        <.icon name="hero-document-text" class="size-5" />
      </.button>

      <.button
        id={"inline-add-image-#{@after_id}"}
        phx-hook="TippyTooltip"
        data-tippy-content={gettext("Image")}
        phx-click="add_image_block"
        phx-value-after_id={@after_id}
        class="btn btn-sm btn-ghost btn-square rounded-sm hover:text-primary hover:bg-primary/10"
      >
        <.icon name="hero-photo" class="size-5" />
      </.button>

      <.button
        id={"inline-add-video-#{@after_id}"}
        phx-hook="TippyTooltip"
        data-tippy-content={gettext("Video")}
        phx-click="add_video_block"
        phx-value-after_id={@after_id}
        class="btn btn-sm btn-ghost btn-square rounded-sm hover:text-primary hover:bg-primary/10"
      >
        <.icon name="hero-video-camera" class="size-5" />
      </.button>

      <.button
        id={"inline-add-attachment-#{@after_id}"}
        phx-hook="TippyTooltip"
        data-tippy-content={gettext("Files")}
        phx-click="add_attachment_block"
        phx-value-after_id={@after_id}
        class="btn btn-sm btn-ghost btn-square rounded-sm hover:text-primary hover:bg-primary/10"
      >
        <.icon name="hero-paper-clip" class="size-5" />
      </.button>

      <.button
        id={"inline-add-quiz-#{@after_id}"}
        phx-hook="TippyTooltip"
        data-tippy-content={gettext("Quiz Question")}
        phx-click="add_quiz_question_block"
        phx-value-after_id={@after_id}
        class="btn btn-sm btn-ghost btn-square rounded-sm hover:text-primary hover:bg-primary/10"
      >
        <.icon name="hero-question-mark-circle" class="size-5" />
      </.button>

      <.button
        id={"inline-add-exam-#{@after_id}"}
        phx-hook="TippyTooltip"
        data-tippy-content={gettext("Quiz Exam")}
        phx-click="add_quiz_exam_block"
        phx-value-after_id={@after_id}
        class="btn btn-sm btn-ghost btn-square rounded-sm hover:text-primary hover:bg-primary/10"
      >
        <.icon name="hero-academic-cap" class="size-5" />
      </.button>

      <.button
        id={"inline-add-code-#{@after_id}"}
        phx-hook="TippyTooltip"
        data-tippy-content={gettext("Code Sandbox")}
        phx-click="add_code_block"
        phx-value-after_id={@after_id}
        class="btn btn-sm btn-ghost btn-square rounded-sm hover:text-primary hover:bg-primary/10"
      >
        <.icon name="hero-code-bracket" class="size-5" />
      </.button>

      <div class="divider divider-horizontal mx-0 w-1"></div>

      <.button
        id={"inline-add-library-#{@after_id}"}
        phx-hook="TippyTooltip"
        data-tippy-content={gettext("Add from Library")}
        phx-click="open_library_picker"
        phx-value-after_id={@after_id}
        class="btn btn-sm btn-ghost btn-square rounded-sm text-primary hover:bg-primary/20"
      >
        <.icon name="hero-bookmark-square" class="size-5" />
      </.button>
    </div>
    """
  end
end
