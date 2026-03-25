defmodule AthenaWeb.LearnLive.Player do
  @moduledoc "Player with strict Waterfall bounds and support for all block types."
  use AthenaWeb, :live_view

  alias Athena.Content
  alias Athena.Learning
  alias Athena.Learning.Progress

  @impl true
  def mount(%{"id" => course_id} = params, _session, socket) do
    user = socket.assigns.current_user

    if Learning.has_access?(user.id, course_id) do
      if connected?(socket) do
        Phoenix.PubSub.subscribe(Athena.PubSub, "course_content:#{course_id}")
      end

      course = Content.get_course(course_id) |> elem(1)
      linear_lessons = Content.list_linear_lessons(course_id, user)

      accessible_ids = Progress.accessible_section_ids(user.id, course_id, linear_lessons)
      section_id = params["section_id"] || linear_lessons |> List.first() |> Map.get(:id)

      if section_id not in accessible_ids do
        {:ok,
         socket
         |> put_flash(:error, gettext("You must complete previous lessons first."))
         |> push_navigate(to: ~p"/learn/courses/#{course_id}")}
      else
        section = Content.get_section(section_id) |> elem(1)

        blocks = Content.list_blocks_by_section(section_id, user) |> Enum.sort_by(& &1.order)
        completed_ids = Progress.completed_block_ids(user.id, section_id)
        tree = Content.get_course_tree(course_id, user)

        current_index = Enum.find_index(linear_lessons, fn s -> s.id == section_id end)

        prev_section =
          if current_index > 0, do: Enum.at(linear_lessons, current_index - 1), else: nil

        next_section = Enum.at(linear_lessons, current_index + 1)
        next_accessible? = next_section != nil and next_section.id in accessible_ids

        socket =
          socket
          |> assign(:page_title, section.title)
          |> assign(:course, course)
          |> assign(:tree, tree)
          |> assign(:linear_lessons, linear_lessons)
          |> assign(:section, section)
          |> assign(:blocks, blocks)
          |> assign(:completed_ids, completed_ids)
          |> assign(:prev_section_id, if(prev_section, do: prev_section.id, else: nil))
          |> assign(:next_section_id, if(next_accessible?, do: next_section.id, else: nil))
          |> assign(:course_map_open, false)
          |> assign(:visible_blocks, calc_visible_blocks(blocks, completed_ids))

        {:ok, schedule_next_unlock(socket, course_id)}
      end
    else
      {:ok, push_navigate(socket |> put_flash(:error, gettext("Access denied.")), to: ~p"/learn")}
    end
  end

  @impl true
  def handle_event("complete_gate", %{"block-id" => block_id}, socket) do
    user = socket.assigns.current_user
    {:ok, _} = Progress.mark_completed(user.id, block_id)
    new_completed_ids = [block_id | socket.assigns.completed_ids]

    linear_lessons = socket.assigns.linear_lessons

    accessible_ids =
      Progress.accessible_section_ids(user.id, socket.assigns.course.id, linear_lessons)

    current_index = Enum.find_index(linear_lessons, fn s -> s.id == socket.assigns.section.id end)
    next_section = Enum.at(linear_lessons, current_index + 1)
    next_accessible? = next_section != nil and next_section.id in accessible_ids

    {:noreply,
     socket
     |> assign(:completed_ids, new_completed_ids)
     |> assign(:next_section_id, if(next_accessible?, do: next_section.id, else: nil))
     |> assign(:visible_blocks, calc_visible_blocks(socket.assigns.blocks, new_completed_ids))}
  end

  def handle_event("open_course_map", _, socket),
    do: {:noreply, assign(socket, course_map_open: true)}

  def handle_event("close_course_map", _, socket),
    do: {:noreply, assign(socket, course_map_open: false)}

  defp calc_visible_blocks(blocks, completed_ids) do
    Enum.reduce_while(blocks, [], fn block, acc ->
      is_completed = block.id in completed_ids

      if is_gate?(block) and not is_completed do
        {:halt, acc ++ [block]}
      else
        {:cont, acc ++ [block]}
      end
    end)
  end

  @impl true
  def handle_info(:refresh_content, socket) do
    user = socket.assigns.current_user
    course_id = socket.assigns.course.id
    current_section_id = socket.assigns.section.id

    linear_lessons = Content.list_linear_lessons(course_id, user)
    accessible_ids = Progress.accessible_section_ids(user.id, course_id, linear_lessons)

    if current_section_id not in accessible_ids do
      {:noreply,
       socket
       |> put_flash(
         :warning,
         gettext("The instructor modified this content. Returning to safe zone.")
       )
       |> push_navigate(to: ~p"/learn/courses/#{course_id}")}
    else
      blocks =
        Content.list_blocks_by_section(current_section_id, user) |> Enum.sort_by(& &1.order)

      completed_ids = Progress.completed_block_ids(user.id, current_section_id)
      tree = Content.get_course_tree(course_id, user)

      current_index = Enum.find_index(linear_lessons, fn s -> s.id == current_section_id end)
      next_section = Enum.at(linear_lessons, current_index + 1)
      next_accessible? = next_section != nil and next_section.id in accessible_ids

      {:noreply,
       socket
       |> assign(:tree, tree)
       |> assign(:linear_lessons, linear_lessons)
       |> assign(:blocks, blocks)
       |> assign(:completed_ids, completed_ids)
       |> assign(:next_section_id, if(next_accessible?, do: next_section.id, else: nil))
       |> assign(:visible_blocks, calc_visible_blocks(blocks, completed_ids))
       |> schedule_next_unlock(course_id)}
    end
  end

  defp is_gate?(block), do: block.completion_rule && block.completion_rule.type != :none

  defp all_blocks_completed?(visible_blocks, completed_ids) do
    last_block = List.last(visible_blocks)
    last_block == nil or (!is_gate?(last_block) or last_block.id in completed_ids)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-3xl mx-auto py-10 pb-32">
      <div class="flex items-center justify-between mb-12 border-b border-base-200 pb-6">
        <a
          href={"/learn/courses/#{@course.id}"}
          class="inline-flex items-center gap-2 text-sm font-medium text-base-content/50 hover:text-base-content transition-colors"
        >
          <.icon name="hero-arrow-left" class="size-4" />
          <span class="hidden sm:inline">{gettext("Back to Syllabus")}</span>
        </a>

        <div class="flex items-center gap-2">
          <%= if @prev_section_id do %>
            <.link
              navigate={~p"/learn/courses/#{@course.id}/play/#{@prev_section_id}"}
              class="btn btn-ghost btn-sm btn-square text-base-content/70 hover:text-primary"
            >
              <.icon name="hero-chevron-left" class="size-5" />
            </.link>
          <% end %>

          <button
            phx-click="open_course_map"
            class="btn btn-ghost btn-sm text-base-content/70 hover:text-primary"
          >
            <.icon name="hero-map" class="size-4" />
            <span class="hidden sm:inline">{gettext("Course Map")}</span>
          </button>

          <%= if @next_section_id && all_blocks_completed?(@visible_blocks, @completed_ids) do %>
            <.link
              navigate={~p"/learn/courses/#{@course.id}/play/#{@next_section_id}"}
              class="btn btn-ghost btn-sm btn-square text-base-content/70 hover:text-primary"
            >
              <.icon name="hero-chevron-right" class="size-5" />
            </.link>
          <% end %>
        </div>
      </div>

      <h1 class="text-3xl md:text-4xl font-display font-black text-base-content mb-12">
        {@section.title}
      </h1>

      <div class="space-y-10">
        <%= for block <- @visible_blocks do %>
          <div
            id={"block-wrapper-#{block.id}"}
            class="animate-in slide-in-from-bottom-4 fade-in duration-500 fill-mode-both"
          >
            <.render_block_content block={block} />
            <div :if={is_gate?(block)} class="mt-8">
              <.render_gate block={block} is_completed={block.id in @completed_ids} />
            </div>
          </div>
        <% end %>
      </div>

      <div
        :if={all_blocks_completed?(@visible_blocks, @completed_ids)}
        class="mt-20 pt-10 border-t border-base-300 animate-in fade-in slide-in-from-bottom-8 duration-1000"
      >
        <div class="bg-base-200/50 rounded-3xl p-10 text-center">
          <div class="size-16 bg-success/20 text-success rounded-full flex items-center justify-center mx-auto mb-6">
            <.icon name="hero-check-badge-solid" class="size-10" />
          </div>
          <h3 class="text-2xl font-black mb-2">{gettext("Lesson Completed!")}</h3>

          <%= if @next_section_id do %>
            <.link
              navigate={~p"/learn/courses/#{@course.id}/play/#{@next_section_id}"}
              class="btn btn-primary btn-lg px-12 mt-6"
            >
              {gettext("Next Lesson")} <.icon name="hero-arrow-right" class="size-5 ml-2" />
            </.link>
          <% else %>
            <p class="text-base-content/60 mt-4 font-bold uppercase tracking-widest">
              {gettext("Course Completed!")}
            </p>
            <.link
              navigate={~p"/learn/courses/#{@course.id}"}
              class="btn btn-outline btn-lg px-12 mt-6"
            >
              {gettext("Back to Syllabus")}
            </.link>
          <% end %>
        </div>
      </div>

      <.modal
        :if={@course_map_open}
        id="course-map-modal"
        show={true}
        title={gettext("Course Map")}
        on_cancel={JS.push("close_course_map")}
      >
        <div class="max-h-[60vh] overflow-y-auto -mx-6 px-6 py-2">
          <.course_map_tree sections={@tree} active_section_id={@section.id} course_id={@course.id} />
        </div>
      </.modal>
    </div>
    """
  end

  def course_map_tree(assigns) do
    assigns = assign_new(assigns, :level, fn -> 0 end)

    ~H"""
    <div class="space-y-1">
      <div :for={section <- @sections}>
        <%= if section.children == [] do %>
          <.link
            navigate={~p"/learn/courses/#{@course_id}/play/#{section.id}"}
            class={[
              "w-full justify-start px-3 py-2.5 rounded-lg flex items-center gap-3 text-sm transition-all group font-medium",
              @active_section_id == section.id && "bg-primary/10 text-primary",
              @active_section_id != section.id && "hover:bg-base-200 text-base-content/70"
            ]}
            style={"padding-left: #{(@level * 1.5) + 0.75}rem;"}
          >
            <.icon
              name="hero-document-text"
              class={[
                "size-4 shrink-0 transition-colors",
                @active_section_id == section.id && "text-primary",
                @active_section_id != section.id && "text-base-content/30 group-hover:text-primary/70"
              ]}
            />
            <span class="truncate">{section.title}</span>
          </.link>
        <% else %>
          <div
            class="w-full flex items-center gap-2 text-xs text-base-content/40 uppercase tracking-widest font-black mt-4 mb-2"
            style={"padding-left: #{(@level * 1.5) + 0.75}rem;"}
          >
            <.icon name="hero-folder" class="size-4 shrink-0" />
            <span class="truncate">{section.title}</span>
          </div>
        <% end %>
        <.course_map_tree
          :if={section.children != []}
          sections={section.children}
          active_section_id={@active_section_id}
          course_id={@course_id}
          level={@level + 1}
        />
      </div>
    </div>
    """
  end

  defp render_block_content(%{block: %{type: :text}} = assigns) do
    ~H"""
    <div
      id={"player-tiptap-#{@block.id}-#{DateTime.to_unix(@block.updated_at)}"}
      phx-hook="TiptapEditor"
      data-id={@block.id}
      data-readonly="true"
      phx-update="ignore"
      data-content={Jason.encode!(@block.content)}
      class="prose prose-base md:prose-lg max-w-none text-base-content/80 leading-relaxed"
    >
    </div>
    """
  end

  defp render_block_content(%{block: %{type: :image}} = assigns) do
    ~H"""
    <%= if @block.content["url"] do %>
      <figure class="m-0 my-8">
        <img
          src={@block.content["url"]}
          alt={@block.content["alt"]}
          class="rounded-xl w-full object-cover border border-base-200 shadow-sm"
        />
      </figure>
    <% end %>
    """
  end

  defp render_block_content(%{block: %{type: :video}} = assigns) do
    ~H"""
    <%= if @block.content["url"] do %>
      <div class="my-8">
        <video
          src={@block.content["url"]}
          poster={@block.content["poster_url"]}
          controls={@block.content["controls"] not in [false, "false"]}
          class="rounded-xl w-full bg-black aspect-video shadow-md"
        />
      </div>
    <% end %>
    """
  end

  defp render_block_content(%{block: %{type: :attachment}} = assigns) do
    ~H"""
    <div class="my-8 p-6 bg-base-200/50 rounded-xl border border-base-300">
      <div
        :if={@block.content["description"]}
        id={"player-attachment-tiptap-#{@block.id}-#{DateTime.to_unix(@block.updated_at)}"}
        phx-hook="TiptapEditor"
        data-id={"desc-#{@block.id}"}
        data-readonly="true"
        phx-update="ignore"
        data-content={Jason.encode!(@block.content["description"])}
        class="prose prose-sm max-w-none text-base-content/70 mb-4"
      >
      </div>
      <div class="space-y-3 mt-4">
        <a
          :for={file <- @block.content["files"] || []}
          href={file["url"]}
          target="_blank"
          rel="noopener noreferrer"
          class="flex items-center gap-4 p-4 bg-base-100 rounded-lg border border-base-200 shadow-sm hover:border-primary/40 hover:shadow-md transition-all group"
        >
          <div class="p-3 bg-primary/10 rounded-lg text-primary shrink-0 group-hover:scale-110 transition-transform">
            <.icon name="hero-document-arrow-down" class="size-6" />
          </div>
          <div class="flex-1 min-w-0">
            <div class="font-bold text-base-content truncate group-hover:text-primary transition-colors">
              {file["name"]}
            </div>
            <div class="text-xs text-base-content/50 mt-0.5">{format_bytes(file["size"])}</div>
          </div>
          <.icon
            name="hero-arrow-down-tray"
            class="size-5 text-base-content/30 group-hover:text-primary shrink-0"
          />
        </a>
      </div>
    </div>
    """
  end

  defp render_block_content(%{block: %{type: :code}} = assigns) do
    ~H"""
    <div class="my-8 overflow-hidden rounded-xl border border-base-300 bg-base-300/20">
      <div class="bg-base-300 px-4 py-2 flex items-center gap-2">
        <div class="size-3 rounded-full bg-error"></div>
        <div class="size-3 rounded-full bg-warning"></div>
        <div class="size-3 rounded-full bg-success"></div>
        <span class="ml-2 text-xs font-mono text-base-content/50">editor.ex</span>
      </div>
      <pre class="p-4 text-sm font-mono overflow-x-auto text-base-content/80">{@block.content["code"]}</pre>
    </div>
    """
  end

  defp render_block_content(assigns),
    do: ~H"""
    <div class="p-4 bg-base-200 rounded-lg text-sm text-base-content/50 italic">
      [{gettext("Content type:")} {@block.type}]
    </div>
    """

  defp render_gate(%{block: %{completion_rule: %{type: :button}}} = assigns) do
    ~H"""
    <div class="py-2 border-t border-base-100">
      <%= if @is_completed do %>
        <div class="flex items-center gap-2 text-success font-bold text-sm">
          <.icon name="hero-check-circle-solid" class="size-5" /> {gettext("Completed")}
        </div>
      <% else %>
        <button
          phx-click="complete_gate"
          phx-value-block-id={@block.id}
          class="btn btn-primary px-10 shadow-lg shadow-primary/20"
        >
          {@block.completion_rule.button_text || gettext("Continue")}
        </button>
      <% end %>
    </div>
    """
  end

  defp render_gate(%{block: %{completion_rule: %{type: :submit}}} = assigns) do
    ~H"""
    <div class="p-6 bg-warning/10 border border-warning/30 rounded-xl">
      <div class="font-bold text-warning mb-2">{gettext("Task Submission Required")}</div>
      <p class="text-sm mb-4 text-warning/80">
        {gettext(
          "This block requires you to submit an answer. Submissions module is under development."
        )}
      </p>
      <button
        :if={not @is_completed}
        phx-click="complete_gate"
        phx-value-block-id={@block.id}
        class="btn btn-warning btn-sm"
      >
        {gettext("Simulate Pass")}
      </button>
      <div :if={@is_completed} class="text-success font-bold text-sm flex items-center gap-1">
        <.icon name="hero-check-circle" class="size-4" /> Submitted
      </div>
    </div>
    """
  end

  defp render_gate(%{block: %{completion_rule: %{type: :pass_auto_grade}}} = assigns) do
    ~H"""
    <div class="p-6 bg-info/10 border border-info/30 rounded-xl">
      <div class="font-bold text-info mb-2">{gettext("Auto-Graded Task")}</div>
      <p class="text-sm mb-4 text-info/80">
        {gettext("Minimum score required: %{score}", score: @block.completion_rule.min_score || 0)}
      </p>
      <button
        :if={not @is_completed}
        phx-click="complete_gate"
        phx-value-block-id={@block.id}
        class="btn btn-info btn-sm"
      >
        {gettext("Simulate Pass")}
      </button>
      <div :if={@is_completed} class="text-success font-bold text-sm flex items-center gap-1">
        <.icon name="hero-check-circle" class="size-4" /> Passed
      </div>
    </div>
    """
  end

  defp render_gate(assigns), do: ~H""

  @doc false
  defp format_bytes(bytes) do
    cond do
      is_nil(bytes) -> "0 B"
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 1)} MB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024, 1)} KB"
      true -> "#{bytes} B"
    end
  end

  @doc false
  defp schedule_next_unlock(socket, course_id) do
    now_unix = DateTime.utc_now() |> DateTime.to_unix()

    all_sections = Content.list_linear_lessons(course_id, :all)
    all_section_ids = Enum.map(all_sections, & &1.id)

    import Ecto.Query

    all_blocks =
      Athena.Repo.all(from b in Athena.Content.Block, where: b.section_id in ^all_section_ids)

    all_rules =
      (all_sections ++ all_blocks)
      |> Enum.map(& &1.access_rules)
      |> Enum.reject(&is_nil/1)

    all_times =
      all_rules
      |> Enum.flat_map(&[&1.unlock_at, &1.lock_at])
      |> Enum.reject(&is_nil/1)

    future_unix_times =
      all_times
      |> Enum.map(&parse_to_unix/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(&(&1 > now_unix))
      |> Enum.sort()

    case List.first(future_unix_times) do
      nil ->
        socket

      target_unix ->
        raw_diff_ms = (target_unix - now_unix) * 1000 + 1000
        safe_diff_ms = min(raw_diff_ms, 86_400_000)
        Process.send_after(self(), :refresh_content, safe_diff_ms)
        socket
    end
  end

  defp parse_to_unix(%DateTime{} = dt), do: DateTime.to_unix(dt)

  defp parse_to_unix(%NaiveDateTime{} = ndt),
    do: DateTime.from_naive!(ndt, "Etc/UTC") |> DateTime.to_unix()

  defp parse_to_unix(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} ->
        DateTime.to_unix(dt)

      {:error, _} ->
        case NaiveDateTime.from_iso8601(str) do
          {:ok, ndt} -> DateTime.from_naive!(ndt, "Etc/UTC") |> DateTime.to_unix()
          _ -> nil
        end
    end
  end

  defp parse_to_unix(_), do: nil
end
