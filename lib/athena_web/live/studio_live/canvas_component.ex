defmodule AthenaWeb.StudioLive.Builder.CanvasComponent do
  @moduledoc """
  LiveComponent for rendering the main canvas with blocks.
  """
  use AthenaWeb, :live_component

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
              "group relative rounded-lg border-2 transition-all cursor-pointer bg-base-100",
              @active_block_id == block.id && "border-primary shadow-sm",
              @active_block_id != block.id && "border-transparent hover:border-base-300"
            ]}
          >
            <div class="absolute -left-10 top-1/2 -translate-y-1/2 p-2 opacity-0 group-hover:opacity-50 hover:opacity-100! cursor-grab drag-handle transition-opacity hidden sm:block">
              <.icon name="hero-bars-3" class="size-5" />
            </div>

            <div class="p-6">
              <%= if block.type == :text do %>
                <div
                  id={"tiptap-#{block.id}"}
                  phx-hook="TiptapEditor"
                  data-id={block.id}
                  phx-update="ignore"
                  data-content={Jason.encode!(block.content)}
                  class="min-h-[100px]"
                >
                </div>
              <% else %>
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

        <div class="sticky bottom-4 mt-auto flex justify-center z-20 pointer-events-none pb-8">
          <div class="pointer-events-auto bg-base-100 rounded-full shadow-xl ring-1 ring-base-300 p-1 flex gap-1">
            <button phx-click="add_text_block" class="btn btn-primary rounded-full px-6">
              <.icon name="hero-align-left" class="size-4" />
              {gettext("Text")}
            </button>
            <button phx-click="add_code_block" class="btn btn-neutral btn-soft rounded-full px-6">
              <.icon name="hero-code-bracket" class="size-4" />
              {gettext("Code")}
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
