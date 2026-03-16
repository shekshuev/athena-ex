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
                  {gettext("Text Block")}
                </.button>
              </li>
              <li>
                <.button
                  phx-click="add_code_block"
                  class="btn btn-ghost justify-start font-medium gap-3 h-12"
                >
                  {gettext("Code Sandbox")}
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
