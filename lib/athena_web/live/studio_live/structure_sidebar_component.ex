defmodule AthenaWeb.StudioLive.Builder.StructureSidebarComponent do
  @moduledoc """
  LiveComponent for rendering the course structure in the Builder.
  """
  use AthenaWeb, :live_component

  @impl true
  def render(assigns) do
    current_level_sections =
      if assigns.viewing_parent_id do
        case find_section(assigns.sections, assigns.viewing_parent_id) do
          nil -> []
          parent -> parent.children || []
        end
      else
        assigns.sections
      end

    assigns = assign(assigns, :current_level_sections, current_level_sections)

    ~H"""
    <div class="flex flex-col h-full bg-base-100">
      <div class="h-14 shrink-0 border-b border-base-300 flex items-center justify-between px-4 gap-3">
        <h3 class="font-bold text-sm uppercase tracking-wider text-base-content/70">
          {gettext("Navigation")}
        </h3>
        <.link navigate={~p"/studio/courses"} class="btn btn-ghost btn-xs btn-square">
          <.icon name="hero-x-mark" class="size-4" />
        </.link>
      </div>

      <div class="px-2 py-2 border-b border-base-300 bg-base-100 shrink-0 flex gap-2">
        <button
          :if={@viewing_parent_id}
          type="button"
          phx-click="drill_up"
          phx-value-id={@viewing_parent_id}
          class="btn btn-ghost btn-xs flex-1 gap-1"
        >
          <.icon name="hero-arrow-up" class="size-3" />
          {gettext("Up")}
        </button>

        <button
          :if={@role in [:owner, :writer]}
          type="button"
          phx-click="add_section"
          phx-value-parent_id={@viewing_parent_id || ""}
          class="btn btn-ghost btn-xs flex-1 gap-1 text-primary"
        >
          <.icon name="hero-plus" class="size-3.5" />
          {gettext("Add Section")}
        </button>
      </div>

      <div
        id={"sidebar-level-#{@viewing_parent_id || "root"}"}
        phx-hook={if @role in [:owner, :writer], do: "Sortable", else: nil}
        data-event-name="reorder_section"
        class="flex-1 overflow-y-auto space-y-0.5 p-2 pb-20"
      >
        <div
          :for={section <- @current_level_sections}
          id={"section-#{section.id}"}
          data-id={section.id}
          class={[
            "group flex items-center justify-between px-3 py-2 rounded-sm cursor-pointer transition-colors text-sm",
            @active_section_id == section.id && "bg-primary/10 text-primary font-bold",
            @active_section_id != section.id && "hover:bg-base-200 text-base-content/80"
          ]}
        >
          <div class="flex items-center gap-2 overflow-hidden flex-1">
            <.icon
              name="hero-bars-3"
              class="drag-handle size-4 opacity-0 group-hover:opacity-50 hover:opacity-100! cursor-grab shrink-0 transition-opacity"
            />
            <div
              id={"section-title-#{section.id}"}
              class="truncate flex-1"
              phx-click="select_section"
              phx-value-id={section.id}
              phx-hook="DblClickDrillDown"
              data-drill-id={section.id}
              title={section.title}
            >
              {section.title}
            </div>

            <button
              :if={@role in [:owner, :writer]}
              type="button"
              phx-click="add_section"
              phx-value-parent_id={section.id}
              class="opacity-0 group-hover:opacity-100 hover:bg-primary/10 hover:text-primary min-h-6 h-6 w-6 flex items-center justify-center rounded-sm transition-opacity shrink-0"
              title={gettext("Add section here")}
            >
              <.icon name="hero-plus" class="size-3.5" />
            </button>
          </div>

          <button
            :if={section.children && section.children != []}
            type="button"
            phx-click="drill_down"
            phx-value-id={section.id}
            class="min-h-6 h-6 w-6 flex items-center justify-center rounded-sm hover:bg-base-300 text-base-content/50 hover:text-primary transition-colors shrink-0"
            title={gettext("Drill down")}
          >
            <.icon name="hero-chevron-right" class="size-4" />
          </button>
        </div>

        <div
          :if={@current_level_sections == []}
          class="text-xs text-base-content/50 italic p-4 text-center"
        >
          <%= if @viewing_parent_id do %>
            {gettext("This folder is empty.")}
          <% else %>
            {gettext("No sections yet. Create your first one!")}
          <% end %>
        </div>
      </div>

      <div class="flex items-center justify-around p-4 group-[.is-collapsed]/sidebar:flex-col group-[.is-collapsed]/sidebar:gap-3">
        <% current_locale = Gettext.get_locale(AthenaWeb.Gettext) %>
        <a
          href={"/locale/#{if current_locale == "ru", do: "en", else: "ru"}"}
          class="btn btn-ghost btn-sm font-bold opacity-70 hover:opacity-100"
        >
          {String.upcase(current_locale)}
        </a>

        <button
          type="button"
          phx-click="open_quick_nav"
          class="btn btn-ghost btn-sm btn-square opacity-70 hover:opacity-100"
          title={gettext("Open Course Map")}
        >
          <.icon name="hero-map" class="size-5" />
        </button>

        <.link
          navigate={~p"/studio/courses/#{@course.id}/library"}
          class="btn btn-ghost btn-sm font-bold opacity-70 hover:opacity-100"
        >
          <.icon name="hero-bookmark-square" class="size-5" />
        </.link>

        <label class="btn btn-ghost btn-sm btn-square swap swap-rotate opacity-70 hover:opacity-100">
          <input
            type="checkbox"
            value="dark"
            onchange="window.dispatchEvent(new CustomEvent('phx:set-theme', {detail: {theme: this.checked ? 'dark' : 'light'}}))"
          />
          <.icon name="hero-sun" class="swap-off size-5" />
          <.icon name="hero-moon" class="swap-on size-5" />
        </label>
      </div>
    </div>
    """
  end

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
end
