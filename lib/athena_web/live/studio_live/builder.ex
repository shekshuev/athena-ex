defmodule AthenaWeb.StudioLive.Builder do
  @moduledoc """
  The mother of all views: Course Builder Studio.
  Handles the layout and global state for the Sidebar, Canvas, and Inspector.
  """
  use AthenaWeb, :live_view

  alias Athena.Content

  on_mount {AthenaWeb.Hooks.Permission, "courses.update"}

  @impl true
  def mount(%{"id" => course_id}, _session, socket) do
    case Content.get_course(course_id) do
      {:ok, course} ->
        sections = Content.get_course_tree(course.id)
        active_section_id = if sections != [], do: hd(sections).id, else: nil

        blocks =
          if active_section_id,
            do: Content.list_blocks_by_section(active_section_id),
            else: []

        {:ok,
         socket
         |> assign(
           course: course,
           sections: sections,
           active_section_id: active_section_id,
           active_block_id: nil,
           blocks: blocks
         )}

      _ ->
        {:ok, push_navigate(socket, to: ~p"/studio/courses")}
    end
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("select_section", %{"id" => id}, socket) do
    blocks = Content.list_blocks_by_section(id)
    {:noreply, assign(socket, active_section_id: id, active_block_id: nil, blocks: blocks)}
  end

  def handle_event("add_section", _, socket) do
    course = socket.assigns.course

    attrs = %{
      "title" => gettext("New Lesson"),
      "course_id" => course.id,
      "owner_id" => socket.assigns.current_user.id
    }

    case Content.create_section(attrs) do
      {:ok, new_section} ->
        updated_sections = socket.assigns.sections ++ [new_section]

        {:noreply,
         socket
         |> assign(sections: updated_sections, active_section_id: new_section.id)
         |> put_flash(:info, gettext("Section added"))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to add section"))}
    end
  end

  def handle_event(
        "reorder",
        %{"id" => _id, "new_index" => _new_index, "old_index" => _old_index},
        socket
      ) do
    {:noreply, socket}
  end

  def handle_event("select_block", %{"id" => id}, socket) do
    {:noreply, assign(socket, active_block_id: id)}
  end

  def handle_event("add_text_block", _, socket) do
    attrs = %{
      "type" => "text",
      "content" => %{"type" => "doc", "content" => [%{"type" => "paragraph"}]},
      "section_id" => socket.assigns.active_section_id
    }

    case Content.create_block(attrs) do
      {:ok, block} ->
        updated_blocks = socket.assigns.blocks ++ [block]
        {:noreply, assign(socket, blocks: updated_blocks, active_block_id: block.id)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to create block"))}
    end
  end

  def handle_event("add_code_block", _, socket) do
    attrs = %{
      "type" => "code",
      "content" => %{"code" => "IO.puts(:hello)"},
      "section_id" => socket.assigns.active_section_id
    }

    case Content.create_block(attrs) do
      {:ok, block} ->
        updated_blocks = socket.assigns.blocks ++ [block]
        {:noreply, assign(socket, blocks: updated_blocks, active_block_id: block.id)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to create block"))}
    end
  end

  def handle_event("update_content", %{"id" => id, "content" => content}, socket) do
    with %Athena.Content.Block{} = block <- Enum.find(socket.assigns.blocks, &(&1.id == id)),
         {:ok, updated_block} <- Content.update_block(block, %{"content" => content}) do
      updated_blocks =
        Enum.map(socket.assigns.blocks, fn
          %Athena.Content.Block{id: ^id} -> updated_block
          other_block -> other_block
        end)

      {:noreply, assign(socket, blocks: updated_blocks)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("reorder_block", %{"id" => id, "new_index" => new_index}, socket) do
    blocks = socket.assigns.blocks
    block = Enum.find(blocks, &(&1.id == id))

    blocks_without_target = Enum.reject(blocks, &(&1.id == id))

    reordered = List.insert_at(blocks_without_target, new_index, block)

    prev = if new_index > 0, do: Enum.at(reordered, new_index - 1), else: nil
    next = Enum.at(reordered, new_index + 1)

    new_order =
      cond do
        is_nil(prev) ->
          if next, do: div(next.order, 2), else: 1024

        is_nil(next) ->
          prev.order + 1024

        true ->
          div(prev.order + next.order, 2)
      end

    {:ok, updated_block} = Content.reorder_block(block, new_order)

    final_blocks =
      reordered
      |> Enum.map(fn b -> if b.id == id, do: updated_block, else: b end)
      |> Enum.sort_by(& &1.order)

    {:noreply, assign(socket, blocks: final_blocks)}
  end

  def handle_event("update_section_meta", %{"title" => title}, socket) do
    section = find_section_in_tree(socket.assigns.sections, socket.assigns.active_section_id)

    {:ok, _updated_section} = Content.update_section(section, %{"title" => title})

    updated_sections = Content.get_course_tree(socket.assigns.course.id)
    {:noreply, assign(socket, sections: updated_sections)}
  end

  def handle_event("delete_section", %{"id" => id}, socket) do
    section = find_section_in_tree(socket.assigns.sections, id)
    {:ok, _} = Content.delete_section(section)

    updated_sections = Content.get_course_tree(socket.assigns.course.id)
    {:noreply, assign(socket, sections: updated_sections, active_section_id: nil, blocks: [])}
  end

  def handle_event("update_block_meta", params, socket) do
    id = params["id"]

    with %Athena.Content.Block{} = block <- Enum.find(socket.assigns.blocks, &(&1.id == id)) do
      meta_params = Map.drop(params, ["id", "_csrf_token", "_target"])

      new_content = Map.merge(block.content || %{}, meta_params)

      {:ok, updated_block} = Content.update_block(block, %{"content" => new_content})

      updated_blocks =
        Enum.map(socket.assigns.blocks, fn b ->
          if b.id == id, do: updated_block, else: b
        end)

      {:noreply, assign(socket, blocks: updated_blocks)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("delete_block", %{"id" => id}, socket) do
    block = Enum.find(socket.assigns.blocks, &(&1.id == id))
    {:ok, _} = Content.delete_block(block)

    updated_blocks = Enum.reject(socket.assigns.blocks, &(&1.id == id))
    {:noreply, assign(socket, blocks: updated_blocks, active_block_id: nil)}
  end

  @impl true
  def render(assigns) do
    active_section = find_section_in_tree(assigns.sections, assigns.active_section_id)
    active_block = Enum.find(assigns.blocks, &(&1.id == assigns.active_block_id))

    assigns = assign(assigns, active_section: active_section, active_block: active_block)

    ~H"""
    <div class="fixed inset-0 pt-16 lg:pt-0 z-50 flex bg-base-200">
      <div class="w-80 flex flex-col bg-base-100 border-r border-base-300 shrink-0 z-10">
        <div class="p-4 border-b border-base-300 flex items-center justify-between">
          <h2 class="font-bold truncate" title={@course.title}>{@course.title}</h2>
          <.link navigate={~p"/studio/courses"} class="btn btn-ghost btn-xs btn-square">
            <.icon name="hero-x-mark" class="size-4" />
          </.link>
        </div>

        <div class="flex-1 overflow-hidden p-4 flex flex-col">
          <.live_component
            module={AthenaWeb.StudioLive.Builder.StructureSidebarComponent}
            id="structure-sidebar"
            sections={@sections}
            active_section_id={@active_section_id}
          />
        </div>
      </div>

      <div class="flex-1 flex flex-col relative overflow-hidden bg-base-200">
        <div class="flex-1 flex flex-col relative overflow-hidden bg-base-200">
          <div class="flex-1 overflow-y-auto p-8 relative">
            <div class="max-w-3xl mx-auto min-h-full flex flex-col gap-4">
              <.live_component
                module={AthenaWeb.StudioLive.Builder.CanvasComponent}
                id="canvas-component"
                blocks={@blocks}
                active_section_id={@active_section_id}
                active_block_id={@active_block_id}
              />
            </div>
          </div>
        </div>
      </div>

      <div class="w-80 flex flex-col bg-base-100 border-l border-base-300 shrink-0 z-10">
        <div class="p-4 border-b border-base-300">
          <h3 class="font-bold text-sm uppercase tracking-wider text-base-content/70">
            {gettext("Inspector")}
          </h3>
        </div>

        <div class="flex-1 overflow-hidden p-4 flex flex-col">
          <.live_component
            module={AthenaWeb.StudioLive.Builder.InspectorComponent}
            id="inspector-component"
            active_section={@active_section}
            active_block={@active_block}
          />
        </div>
      </div>
    </div>
    """
  end

  defp find_section_in_tree(_, nil), do: nil

  defp find_section_in_tree(sections, id) do
    Enum.find_value(sections, fn section ->
      if section.id == id do
        section
      else
        find_section_in_tree(section.children || [], id)
      end
    end)
  end
end
