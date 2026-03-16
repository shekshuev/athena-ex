defmodule AthenaWeb.StudioLive.Builder.StructureSidebarComponent do
  @moduledoc """
  LiveComponent for rendering the list of sections (lessons) in the Builder.
  Handles Drag-and-Drop ordering and selecting the active section.
  """
  use AthenaWeb, :live_component

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col h-full">
      <div
        id="sidebar-sections-list"
        phx-hook="Sortable"
        class="flex-1 overflow-y-auto space-y-1 pr-2 pb-4"
      >
        <div
          :for={section <- @sections}
          id={"section-#{section.id}"}
          data-id={section.id}
          phx-click="select_section"
          phx-value-id={section.id}
          class={[
            "group flex items-center justify-between px-3 py-2 rounded-md cursor-pointer transition-colors text-sm",
            @active_section_id == section.id && "bg-primary/10 text-primary font-bold",
            @active_section_id != section.id && "hover:bg-base-200 text-base-content/80"
          ]}
        >
          <div class="flex items-center gap-3 overflow-hidden">
            <.icon
              name="hero-bars-2"
              class="drag-handle size-4 opacity-0 group-hover:opacity-50 hover:!opacity-100 cursor-grab shrink-0 transition-opacity"
            />
            <span class="truncate">{section.title}</span>
          </div>

          <.icon
            :if={@active_section_id == section.id}
            name="hero-chevron-right"
            class="size-4 shrink-0"
          />
        </div>

        <div :if={@sections == []} class="text-xs text-base-content/50 italic p-4 text-center">
          {gettext("No sections yet. Create your first lesson!")}
        </div>
      </div>

      <div class="pt-4 mt-auto border-t border-base-300 shrink-0">
        <button
          type="button"
          phx-click="add_section"
          class="btn btn-soft btn-neutral btn-sm w-full"
        >
          <.icon name="hero-plus" class="size-4" />
          {gettext("Add Section")}
        </button>
      </div>
    </div>
    """
  end
end
