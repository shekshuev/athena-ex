defmodule AthenaWeb.LearnLive.Course do
  @moduledoc """
  Course Syllabus page.
  Minimalist structure of the course acting as the launching pad for the Player.
  """
  use AthenaWeb, :live_view

  alias Athena.Content
  alias Athena.Learning

  @impl true
  def mount(%{"id" => course_id}, _session, socket) do
    user = socket.assigns.current_user

    if Learning.has_access?(user.id, course_id) do
      case Content.get_course(course_id) do
        {:ok, course} ->
          tree = Content.get_course_tree(course_id)

          {:ok,
           socket
           |> assign(:page_title, course.title)
           |> assign(:course, course)
           |> assign(:tree, tree)}

        {:error, :not_found} ->
          {:ok,
           socket
           |> put_flash(:error, gettext("Course not found."))
           |> push_navigate(to: ~p"/learn")}
      end
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("You don't have access to this course."))
       |> push_navigate(to: ~p"/learn")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-6xl mx-auto space-y-8">
      <div class="mb-12">
        <a
          href="/learn"
          class="inline-flex items-center gap-2 text-sm font-medium text-base-content/50 hover:text-base-content mb-6 transition-colors"
        >
          <.icon name="hero-arrow-left" class="size-4" />
          {gettext("Back to Dashboard")}
        </a>

        <h1 class="text-4xl font-display font-black text-base-content tracking-tight mb-4">
          {@course.title}
        </h1>

        <p class="text-lg text-base-content/70 leading-relaxed mb-8">
          {@course.description || gettext("No description provided.")}
        </p>

        <a href={"/learn/courses/#{@course.id}/play"} class="btn btn-primary px-8">
          {gettext("Start Learning")}
        </a>
      </div>

      <div>
        <h2 class="text-xl font-bold mb-6">{gettext("Syllabus")}</h2>

        <%= if @tree == [] do %>
          <p class="text-base-content/50 italic">{gettext("Content is coming soon.")}</p>
        <% else %>
          <div class="flex flex-col border-t border-base-200">
            <%= for {section, index} <- Enum.with_index(@tree, 1) do %>
              <div class="flex items-center gap-6 py-4 border-b border-base-200 hover:bg-base-200/20 transition-colors">
                <div class="text-sm font-mono text-base-content/40 w-6 text-right shrink-0">
                  {String.pad_leading(Integer.to_string(index), 2, "0")}
                </div>

                <div class="flex-1">
                  <span class="text-base font-medium text-base-content">
                    {section.title}
                  </span>
                </div>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>
    </div>
    """
  end
end
