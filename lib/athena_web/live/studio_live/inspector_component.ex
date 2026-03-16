defmodule AthenaWeb.StudioLive.Builder.InspectorComponent do
  @moduledoc """
  LiveComponent for the right sidebar in the Builder.
  Dynamically renders settings for the currently selected Section or Block.
  """
  use AthenaWeb, :live_component

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col h-full">
      <%= cond do %>
        <% @active_block -> %>
          <.block_inspector block={@active_block} />
        <% @active_section -> %>
          <.section_inspector section={@active_section} />
        <% true -> %>
          <div class="flex-1 flex items-center justify-center p-4 text-center">
            <p class="text-sm text-base-content/50 italic">
              {gettext("Select a section or block to edit settings")}
            </p>
          </div>
      <% end %>
    </div>
    """
  end

  defp section_inspector(assigns) do
    ~H"""
    <div class="flex flex-col h-full animate-in fade-in duration-200">
      <div class="flex items-center gap-3 py-4 border-b border-base-300">
        <div class="p-2 bg-base-200 rounded-md">
          <.icon name="hero-book-open" class="size-5 text-primary" />
        </div>
        <div>
          <div class="text-xs text-base-content/50 font-bold uppercase tracking-wider">
            {gettext("Type")}
          </div>
          <div class="text-sm font-medium">
            {gettext("Lesson")}
          </div>
        </div>
      </div>

      <div class="overflow-y-auto py-4 space-y-6 flex-1">
        <form phx-change="update_section_meta" phx-submit="update_section_meta">
          <.input
            type="text"
            name="title"
            value={@section.title}
            label={gettext("Lesson Title")}
            phx-debounce="500"
          />
        </form>
      </div>

      <div class="pt-4 border-t border-base-300 mt-auto pb-4">
        <button
          type="button"
          phx-click="delete_section"
          phx-value-id={@section.id}
          data-confirm={gettext("Are you sure you want to delete this lesson and all its blocks?")}
          class="btn btn-error btn-soft w-full"
        >
          <.icon name="hero-trash" class="size-4" />
          {gettext("Delete Lesson")}
        </button>
      </div>
    </div>
    """
  end

  defp block_inspector(assigns) do
    ~H"""
    <div class="flex flex-col h-full animate-in fade-in duration-200">
      <div class="flex items-center gap-3 py-4 border-b border-base-300">
        <div class="p-2 bg-base-200 rounded-md">
          <.icon
            name={if @block.type == :code, do: "hero-code-bracket", else: "hero-align-left"}
            class="size-5 text-primary"
          />
        </div>
        <div>
          <div class="text-xs text-base-content/50 font-bold uppercase tracking-wider">
            {gettext("Type")}
          </div>
          <div class="text-sm font-medium capitalize">
            {Atom.to_string(@block.type)} {gettext("Block")}
          </div>
        </div>
      </div>

      <div class="overflow-y-auto py-4 space-y-6 flex-1">
        <form phx-change="update_block_meta">
          <input type="hidden" name="id" value={@block.id} />

          <%= if @block.type == :code do %>
            <div class="space-y-4">
              <div class="text-xs font-semibold text-base-content/50 uppercase tracking-wider">
                {gettext("Execution Settings")}
              </div>
              <.input
                type="select"
                name="language"
                value={@block.content["language"] || "python"}
                label={gettext("Programming Language")}
                options={[{"Python", "python"}, {"SQL", "sql"}, {"Elixir", "elixir"}]}
              />
              <.input
                type="select"
                name="execution_mode"
                value={@block.content["execution_mode"] || "run"}
                label={gettext("Execution Mode")}
                options={[{"Run Code", "run"}, {"Unit Tests", "test"}]}
              />
            </div>
          <% else %>
            <div class="alert alert-info text-sm shadow-none">
              <.icon name="hero-information-circle" class="size-4 shrink-0 mt-0.5" />
              <span>{gettext("Text blocks don't require additional configuration.")}</span>
            </div>
          <% end %>
        </form>
      </div>

      <div class="pt-4 border-t border-base-300 mt-auto pb-4 space-y-2">
        <button type="button" class="btn btn-primary btn-soft w-full">
          <.icon name="hero-bookmark-square" class="size-4" />
          {gettext("Save to Library")}
        </button>

        <button
          type="button"
          phx-click="delete_block"
          phx-value-id={@block.id}
          data-confirm={gettext("Are you sure you want to delete this block?")}
          class="btn btn-error btn-soft w-full"
        >
          <.icon name="hero-trash" class="size-4" />
          {gettext("Delete Block")}
        </button>
      </div>
    </div>
    """
  end
end
