defmodule AthenaWeb.TeachingLive.CourseTreeComponents do
  @moduledoc """
  Shared recursive course-tree sidebar navigation.

  Extracted from `AthenaWeb.TeachingLive.CohortAccess` so it can be reused
  as-is by `AthenaWeb.TeachingLive.CohortEngagement` - same drill-down UX
  (pick a section or block, see a badge dot on nodes that have "something"),
  just a different meaning for the badge (an access override there, recorded
  engagement activity here) and a different destination path, both supplied
  by the caller instead of hardcoded here.
  """
  use AthenaWeb, :html

  attr :sections, :list, required: true
  attr :active_section_id, :string, default: nil
  attr :level, :integer, default: 0
  attr :node_path, :any, required: true, doc: "fun(section) -> patch path string"
  attr :has_badge, :any, required: true, doc: "fun(section) -> boolean"
  attr :badge_title, :string, default: nil

  def course_tree_nav(assigns) do
    ~H"""
    <div class="space-y-1">
      <div :for={section <- @sections}>
        <.link
          patch={@node_path.(section)}
          class={[
            "w-full justify-between px-3 py-2.5 rounded-sm flex items-center gap-3 transition-all group",
            @active_section_id == section.id && "bg-primary/10 text-primary",
            @active_section_id != section.id && "hover:bg-base-200 text-base-content/70"
          ]}
          style={"padding-left: #{@level * 1.5 + 0.75}rem;"}
        >
          <div class="flex items-center gap-2 truncate">
            <.icon
              name={if section.children == [], do: "hero-document-text", else: "hero-folder"}
              class={[
                "size-4 shrink-0 transition-colors",
                @active_section_id == section.id && "text-primary",
                @active_section_id != section.id &&
                  "text-base-content/30 group-hover:text-primary/70"
              ]}
            />
            <span class={
              if section.children == [],
                do: "text-sm font-medium truncate",
                else: "text-xs uppercase tracking-widest font-black truncate"
            }>
              {section.title}
            </span>
          </div>

          <div
            :if={@has_badge.(section)}
            class="size-2 rounded-sm bg-primary shrink-0"
            title={@badge_title}
          >
          </div>
        </.link>

        <.course_tree_nav
          :if={section.children != []}
          sections={section.children}
          active_section_id={@active_section_id}
          node_path={@node_path}
          has_badge={@has_badge}
          badge_title={@badge_title}
          level={@level + 1}
        />
      </div>
    </div>
    """
  end
end
