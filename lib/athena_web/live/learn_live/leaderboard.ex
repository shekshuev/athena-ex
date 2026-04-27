defmodule AthenaWeb.LearnLive.Leaderboard do
  @moduledoc """
  Real-time leaderboard for competition courses.
  Displays a brutalist, flat table ranking teams by their total score.
  """
  use AthenaWeb, :live_view

  alias Athena.Learning
  alias Athena.Content

  @impl true
  def mount(%{"id" => course_id}, _session, socket) do
    user = socket.assigns.current_user

    with true <- Learning.has_access?(user.id, course_id),
         {:ok, course} <- Content.get_course(course_id) do
      if connected?(socket) do
        Phoenix.PubSub.subscribe(Athena.PubSub, "leaderboard:#{course.id}")
      end

      board = Learning.get_team_leaderboard(course.id)

      {:ok,
       socket
       |> assign(:page_title, gettext("Leaderboard - %{course}", course: course.title))
       |> assign(:course, course)
       |> assign(:board, board)}
    else
      _ ->
        {:ok,
         push_navigate(socket |> put_flash(:error, gettext("Access denied.")), to: ~p"/learn")}
    end
  end

  @impl true
  def handle_info(:update_leaderboard, socket) do
    board = Learning.get_team_leaderboard(socket.assigns.course.id)
    {:noreply, assign(socket, :board, board)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto py-12">
      <div class="pb-10">
        <.link
          navigate={~p"/learn/courses/#{@course.id}"}
          class="inline-flex items-center gap-2 text-xs font-bold uppercase tracking-widest text-base-content/40 hover:text-base-content mb-8 transition-colors"
        >
          <.icon name="hero-arrow-left" class="size-4" />
          {gettext("Back to Syllabus")}
        </.link>

        <h1 class="text-4xl md:text-5xl font-display font-black text-base-content mb-6">
          {@course.title}
        </h1>
      </div>

      <div>
        <table class="w-full text-lg">
          <thead class="text-xs font-bold uppercase tracking-widest text-base-content/50 border-b border-base-200 text-left">
            <tr>
              <th class="py-4 px-2 w-16 text-center">#</th>
              <th class="py-4 px-2">{gettext("Team")}</th>
              <th class="py-4 px-2 text-right">{gettext("Score")}</th>
            </tr>
          </thead>
          <tbody>
            <%= if @board == [] do %>
              <tr>
                <td colspan="3" class="text-center py-16 text-base-content/40 italic font-medium">
                  {gettext("This leaderboard is currently empty.")}
                </td>
              </tr>
            <% else %>
              <%= for {team, index} <- Enum.with_index(@board, 1) do %>
                <tr class={[
                  "border-b border-base-200 transition-colors group hover:bg-base-200/50",
                  (index == 1 and not team.is_disqualified) && "bg-primary/5",
                  team.is_disqualified && "opacity-50 grayscale bg-error/5"
                ]}>
                  <td class="py-5 px-2 text-center font-bold text-base-content/40">
                    <%= if team.is_disqualified do %>
                      <.icon name="hero-no-symbol" class="size-5 text-error" />
                    <% else %>
                      {index}
                    <% end %>
                  </td>
                  <td class="py-5 px-2 font-bold text-base-content flex items-center gap-3">
                    <span class={
                      if index == 1 and not team.is_disqualified, do: "text-primary", else: ""
                    }>
                      {team.team_name}
                    </span>
                  </td>
                  <td class="py-5 px-2 text-right font-mono font-bold text-primary">
                    <%= if team.is_disqualified do %>
                      <span class="badge badge-error badge-sm font-bold uppercase tracking-widest border-0 bg-error/10 text-error">
                        {gettext("Disqualified")}
                      </span>
                    <% else %>
                      {team.total_score}
                    <% end %>
                  </td>
                </tr>
              <% end %>
            <% end %>
          </tbody>
        </table>
      </div>
    </div>
    """
  end
end
