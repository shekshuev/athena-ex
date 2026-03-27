defmodule AthenaWeb.LearnLive.Index do
  @moduledoc """
  Student dashboard displaying enrolled courses.
  Acts as the entry point for the Progressive Disclosure player.
  """
  use AthenaWeb, :live_view

  alias Athena.Learning

  @doc """
  Initializes the student dashboard, fetching all active enrollments
  (both direct and via cohorts) for the current user.
  """
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  @impl true
  def mount(_params, _session, socket) do
    current_user = socket.assigns.current_user

    enrollments = Learning.list_student_enrollments(current_user.id)

    {:ok,
     socket
     |> assign(:page_title, gettext("My Learning"))
     |> assign(:enrollments, enrollments)}
  end

  @doc """
  Renders the dashboard interface, displaying either a grid of enrolled
  courses or an empty state message.
  """
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-6xl mx-auto space-y-8">
      <div class="flex flex-col gap-2">
        <h1 class="text-3xl font-display font-black text-base-content tracking-tight">
          {gettext("My Learning")}
        </h1>
        <p class="text-base-content/60 text-lg">
          {gettext("Pick up where you left off or explore your new programs.")}
        </p>
      </div>

      <div
        :if={@enrollments == []}
        class="text-center py-24 px-6 border-2 border-dashed border-base-300 rounded-3xl bg-base-200/30 mt-8"
      >
        <.icon name="hero-book-open" class="size-20 text-base-content/20 mb-6 mx-auto" />
        <h3 class="text-2xl font-display font-bold text-base-content">{gettext("No courses yet")}</h3>
        <p class="text-base-content/60 mt-3 max-w-md mx-auto text-lg">
          {gettext(
            "You are not enrolled in any courses at the moment. Once you join a cohort or unlock a course, it will appear right here."
          )}
        </p>
      </div>

      <div :if={@enrollments != []} class="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 gap-8 mt-8">
        <%= for enrollment <- @enrollments do %>
          <div class="card bg-base-100 border border-base-200 shadow-sm hover:shadow-xl hover:border-primary/40 transition-all duration-300 overflow-hidden group flex flex-col">
            <div class="h-36 bg-linear-to-br from-base-200 to-base-300 relative overflow-hidden">
              <div class="absolute bottom-4 left-4 z-10">
                <span class={[
                  "badge badge-sm font-bold shadow-sm border-0",
                  if(enrollment.cohort_id,
                    do: "bg-primary text-primary-content",
                    else: "bg-accent text-accent-content"
                  )
                ]}>
                  {if enrollment.cohort_id,
                    do: gettext("Academic Cohort"),
                    else: gettext("Self-paced")}
                </span>
              </div>
            </div>

            <div class="card-body p-6 grow gap-4">
              <div>
                <h2 class="card-title text-xl font-display font-bold group-hover:text-primary transition-colors line-clamp-2">
                  {enrollment.course.title}
                </h2>
                <p class="text-sm text-base-content/60 mt-2 line-clamp-2">
                  {enrollment.course.description ||
                    gettext("No description provided. Dive in to see what it's about!")}
                </p>
              </div>

              <div class="mt-auto pt-6 flex items-center justify-between">
                <div class="flex items-center gap-3">
                  <div
                    class="radial-progress text-primary bg-primary/10 text-[10px] font-bold"
                    style="--value:0; --size:2.5rem; --thickness: 3px;"
                    role="progressbar"
                  >
                    0%
                  </div>
                  <span class="text-xs font-bold text-base-content/50 uppercase tracking-widest">
                    {gettext("Progress")}
                  </span>
                </div>

                <a
                  href={"/learn/courses/#{enrollment.course.id}"}
                  class="btn btn-primary btn-sm group-hover:pr-3 transition-all"
                >
                  {gettext("Enter")}
                  <.icon
                    name="hero-arrow-right"
                    class="size-4 opacity-0 -ml-4 group-hover:opacity-100 group-hover:ml-0 transition-all duration-300"
                  />
                </a>
              </div>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end
end
