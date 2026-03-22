defmodule AthenaWeb.StudioLive.Builder.StructureSidebarComponent do
  @moduledoc """
  LiveComponent for rendering the course structure in the Builder.

  Uses a "Drill-down" UX pattern: displays only one level of the hierarchy at a time
  with breadcrumbs for upward navigation. This ensures stable Drag-and-Drop sorting
  via Sortable.js without the DOM conflicts of deeply nested trees.
  """
  use AthenaWeb, :live_component

  @doc """
  Renders the breadcrumb navigation, current level sections, and add button.
  """
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  @impl true
  def render(assigns) do
    current_parent = find_section(assigns.sections, assigns.viewing_parent_id)

    breadcrumbs = build_breadcrumbs(assigns.sections, current_parent)

    current_level_sections =
      if current_parent do
        current_parent.children || []
      else
        assigns.sections
      end

    assigns =
      assigns
      |> assign(:breadcrumbs, breadcrumbs)
      |> assign(:current_level_sections, current_level_sections)
      |> assign(:current_parent, current_parent)

    ~H"""
    <div class="flex flex-col h-full">
      <div class="px-2 pb-3 mb-2 border-b border-base-200">
        <div class="text-xs font-semibold text-base-content/60 flex flex-wrap items-center gap-1">
          <button
            type="button"
            phx-click="open_quick_nav"
            class="hover:text-primary transition-colors flex items-center"
            title={gettext("Open Course Map")}
          >
            <.icon name="hero-map" class="size-3.5 mr-1" />
            {gettext("Course")}
          </button>

          <span :for={crumb <- @breadcrumbs} class="flex items-center gap-1">
            <.icon name="hero-chevron-right" class="size-3" />
            <button
              type="button"
              phx-click="drill_up"
              phx-value-id={crumb.id}
              class="hover:text-primary transition-colors truncate max-w-[100px]"
              title={crumb.title}
            >
              {crumb.title}
            </button>
          </span>
        </div>
      </div>

      <div
        id={"sidebar-level-#{@viewing_parent_id || "root"}"}
        phx-hook="Sortable"
        data-event-name="reorder_section"
        class="flex-1 overflow-y-auto space-y-1 pr-2 pb-4"
      >
        <div
          :for={section <- @current_level_sections}
          id={"section-#{section.id}"}
          data-id={section.id}
          class={[
            "group flex items-center justify-between px-3 py-2 rounded-md cursor-pointer transition-colors text-sm",
            @active_section_id == section.id && "bg-primary/10 text-primary font-bold",
            @active_section_id != section.id && "hover:bg-base-200 text-base-content/80"
          ]}
        >
          <div class="flex items-center gap-3 overflow-hidden flex-1">
            <.icon
              name="hero-bars-2"
              class="drag-handle size-4 opacity-0 group-hover:opacity-50 hover:opacity-100! cursor-grab shrink-0 transition-opacity"
            />

            <div
              class="truncate flex-1"
              phx-click="select_section"
              phx-value-id={section.id}
            >
              {section.title}
            </div>
          </div>

          <div class="flex items-center gap-2 shrink-0">
            <button
              type="button"
              phx-click="drill_down"
              phx-value-id={section.id}
              class="p-1 rounded hover:bg-base-300 text-base-content/50 hover:text-primary transition-colors"
              title={gettext("Open folder")}
            >
              <.icon name="hero-folder-open" class="size-4" />
            </button>
          </div>
        </div>

        <div
          :if={@current_level_sections == []}
          class="text-xs text-base-content/50 italic p-4 text-center"
        >
          <%= if @current_parent do %>
            {gettext("This folder is empty.")}
          <% else %>
            {gettext("No sections yet. Create your first one!")}
          <% end %>
        </div>
      </div>

      <div class="pt-4 mt-auto border-t border-base-300 shrink-0">
        <button
          type="button"
          phx-click="add_section"
          phx-value-parent_id={@viewing_parent_id || ""}
          class="btn btn-soft btn-neutral btn-sm w-full"
        >
          <.icon name="hero-plus" class="size-4" />
          {gettext("Add Here")}
        </button>
      </div>
    </div>
    """
  end

  # --- Helpers ---

  defp find_section(_, nil), do: nil

  defp find_section(sections, id) do
    Enum.find_value(sections, fn section ->
      if section.id == id do
        section
      else
        find_section(section.children || [], id)
      end
    end)
  end

  defp build_breadcrumbs(_sections, nil), do: []

  defp build_breadcrumbs(sections, current_section) do
    path_ids =
      current_section.path.labels
      |> Enum.map(&String.replace(&1, "_", "-"))

    path_ids
    |> Enum.map(fn id -> find_section(sections, id) end)
    |> Enum.reject(&is_nil/1)
  end
end
