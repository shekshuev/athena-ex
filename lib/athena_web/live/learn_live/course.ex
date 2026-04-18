defmodule AthenaWeb.LearnLive.Course do
  @moduledoc """
  Course Syllabus page with flat, brutalist drill-down navigation and real-time updates.

  Handles the layout and global state for the student-facing syllabus,
  fetching the course tree, computing breadcrumbs, and calculating the highest
  accessible section (waterline) based on the user's progress.
  """
  use AthenaWeb, :live_view

  alias Athena.Content
  alias Athena.Learning

  @doc """
  Initializes the LiveView, verifying user access, subscribing to real-time content updates,
  and calculating the accessible sections and the continue learning waterline.
  """
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  @impl true
  def mount(%{"id" => course_id} = params, _session, socket) do
    user = socket.assigns.current_user
    cohort_id = if params["cohort_id"] == "", do: nil, else: params["cohort_id"]

    with true <- Learning.has_access?(user.id, course_id),
         {:ok, course} <- Content.get_course(course_id) do
      if connected?(socket) do
        Phoenix.PubSub.subscribe(Athena.PubSub, "course_content:#{course_id}")
      end

      overrides = Learning.get_student_overrides(user.id, course_id, cohort_id)
      full_tree = Content.get_course_tree(course_id, user)
      linear_sections = Content.list_linear_lessons(course_id, user)

      accessible_ids =
        Learning.accessible_section_ids(user, course_id, linear_sections, overrides)

      waterline_id = List.last(accessible_ids)

      {:ok,
       socket
       |> assign(:page_title, course.title)
       |> assign(:course, course)
       |> assign(:cohort_id, cohort_id)
       |> assign(:full_tree, full_tree)
       |> assign(:accessible_ids, accessible_ids)
       |> assign(:waterline_id, waterline_id)
       |> assign(:viewing_parent_id, params["parent_id"])}
    else
      _ ->
        {:ok,
         push_navigate(socket |> put_flash(:error, gettext("Access denied.")), to: ~p"/learn")}
    end
  end

  @doc """
  Handles URL parameters for drill-down navigation, resolving the current folder level
  and building breadcrumbs.
  """
  @spec handle_params(map(), String.t(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  @impl true
  def handle_params(params, _url, socket) do
    parent_id = params["parent_id"]
    {current_nodes, breadcrumbs} = get_nodes_and_breadcrumbs(socket.assigns.full_tree, parent_id)

    {:noreply,
     socket
     |> assign(:viewing_parent_id, parent_id)
     |> assign(:current_nodes, current_nodes)
     |> assign(:breadcrumbs, breadcrumbs)}
  end

  @doc """
  Handles real-time updates broadcasted via PubSub when course content changes.
  Recalculates the course tree, accessible IDs, and breadcrumbs dynamically.
  """
  @spec handle_info(atom() | tuple(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  @impl true
  def handle_info(:refresh_content, socket) do
    user = socket.assigns.current_user
    course_id = socket.assigns.course.id

    overrides = Learning.get_student_overrides(user.id, course_id, socket.assigns.cohort_id)
    full_tree = Content.get_course_tree(course_id, user)
    linear_sections = Content.list_linear_lessons(course_id, user)
    accessible_ids = Learning.accessible_section_ids(user, course_id, linear_sections, overrides)
    waterline_id = List.last(accessible_ids)

    {current_nodes, breadcrumbs} =
      get_nodes_and_breadcrumbs(full_tree, socket.assigns.viewing_parent_id)

    {:noreply,
     socket
     |> assign(:full_tree, full_tree)
     |> assign(:accessible_ids, accessible_ids)
     |> assign(:waterline_id, waterline_id)
     |> assign(:current_nodes, current_nodes)
     |> assign(:breadcrumbs, breadcrumbs)}
  end

  @doc """
  Renders the syllabus view.
  """
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto py-12">
      <div class="pb-10">
        <a
          href="/learn"
          class="inline-flex items-center gap-2 text-xs font-bold uppercase tracking-widest text-base-content/40 hover:text-base-content mb-8 transition-colors"
        >
          <.icon name="hero-arrow-left" class="size-4" />
          {gettext("Dashboard")}
        </a>
        <h1 class="text-4xl md:text-5xl font-display font-black text-base-content mb-6">
          {@course.title}
        </h1>
        <p class="text-xl text-base-content/70 mb-10 max-w-2xl leading-relaxed">
          {@course.description}
        </p>

        <%= if @waterline_id do %>
          <.link
            navigate={
              ~p"/learn/courses/#{@course.id}/play/#{@waterline_id}?#{[cohort_id: @cohort_id]}"
            }
            class="btn btn-primary px-10"
          >
            {gettext("Continue Learning")}
          </.link>
        <% end %>

        <%= if @course.type == :competition do %>
          <.link
            navigate={~p"/learn/courses/#{@course.id}/leaderboard"}
            class="btn btn-outline btn-warning"
          >
            <.icon name="hero-trophy" class="size-5 mr-2" />
            {gettext("Leaderboard")}
          </.link>
        <% end %>
      </div>

      <div>
        <div class="flex items-center gap-2 text-sm font-bold uppercase tracking-widest text-base-content/50 mb-6 overflow-x-auto">
          <%= for crumb <- @breadcrumbs do %>
            <.icon name="hero-chevron-right" class="size-4 text-base-content/30 shrink-0 mx-1" />
            <.link
              patch={~p"/learn/courses/#{@course.id}?#{[parent_id: crumb.id, cohort_id: @cohort_id]}"}
              class="hover:text-primary whitespace-nowrap transition-colors"
            >
              {crumb.title}
            </.link>
          <% end %>
        </div>

        <div>
          <%= if @current_nodes == [] do %>
            <div class="py-8 text-base-content/40 italic font-medium">
              {gettext("This section is empty.")}
            </div>
          <% else %>
            <%= for node <- @current_nodes do %>
              <% is_accessible = node.id in @accessible_ids or node.children != [] %>

              <div class={[
                "flex items-center justify-between py-5 border-b border-base-200 transition-all group",
                is_accessible && "hover:border-base-content/40",
                not is_accessible && "opacity-40 pointer-events-none grayscale"
              ]}>
                <div class="flex items-center gap-6 w-full min-w-0">
                  <.icon
                    name={if node.children != [], do: "hero-folder", else: "hero-document-text"}
                    class={[
                      "size-6 transition-colors shrink-0",
                      node.children != [] && "text-base-content",
                      node.children == [] && "text-base-content/30 group-hover:text-primary"
                    ]}
                  />

                  <div class="flex-1 truncate">
                    <.link
                      navigate={
                        ~p"/learn/courses/#{@course.id}/play/#{node.id}?#{[cohort_id: @cohort_id]}"
                      }
                      class="block text-lg font-bold text-base-content group-hover:text-primary transition-colors truncate"
                    >
                      {node.title}
                    </.link>
                  </div>
                </div>

                <div class="flex items-center gap-4 shrink-0 ml-4">
                  <.icon
                    :if={not is_accessible}
                    name="hero-lock-closed"
                    class="size-5 text-base-content/30"
                  />

                  <%= if node.children != [] do %>
                    <.link
                      patch={
                        ~p"/learn/courses/#{@course.id}?#{[parent_id: node.id, cohort_id: @cohort_id]}"
                      }
                      class="p-2 -mr-2 rounded-lg hover:bg-base-200 text-base-content/30 hover:text-primary transition-all"
                      title={gettext("Open Folder")}
                    >
                      <.icon name="hero-folder-open" class="size-6" />
                    </.link>
                  <% end %>
                </div>
              </div>
            <% end %>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  @doc false
  defp get_nodes_and_breadcrumbs(tree, nil), do: {tree, []}

  defp get_nodes_and_breadcrumbs(tree, parent_id) do
    find_node(tree, parent_id, []) || {[], []}
  end

  @doc false
  defp find_node(nodes, target_id, breadcrumbs) do
    Enum.find_value(nodes, fn node ->
      if node.id == target_id do
        {node.children, breadcrumbs ++ [node]}
      else
        find_node(node.children, target_id, breadcrumbs ++ [node])
      end
    end)
  end
end
