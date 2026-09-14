defmodule AthenaWeb.LearnLive.Leaderboard do
  @moduledoc """
  Real-time leaderboard for competition courses.
  Displays a brutalist, flat table ranking teams by their total score.

  Public to any signed-in student, not just enrollees - competitions are
  the one course type meant to be cheered on from the sidelines, so access
  here is gated purely on the course being a published competition, not on
  `Athena.Learning.has_access?/2`'s enrollment check (which still guards
  the course's actual sections/blocks - only the leaderboard is public).
  """
  use AthenaWeb, :live_view

  alias Athena.Content
  alias Athena.Identity
  alias Athena.Learning

  @impl true
  def mount(%{"id" => course_id}, _session, socket) do
    with {:ok, course} <- Content.get_course(course_id),
         true <- course.type == :competition and course.status == :published do
      if connected?(socket) do
        Phoenix.PubSub.subscribe(Athena.PubSub, "leaderboard:#{course.id}")
      end

      board = Learning.get_team_leaderboard(course.id)

      {:ok,
       socket
       |> assign(:page_title, gettext("Leaderboard - %{course}", course: course.title))
       |> assign(:course, course)
       |> assign(:board, board)
       |> assign(:selected_team, nil)
       |> assign(:team_members, [])}
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
  def handle_event("show_team", %{"team_id" => team_id}, socket) do
    team = Enum.find(socket.assigns.board, &(&1.team_id == team_id))

    case Learning.list_cohort_memberships(team_id, %{"page_size" => 500}) do
      {:ok, {memberships, _meta}} ->
        {:noreply,
         socket
         |> assign(:selected_team, team)
         |> assign(:team_members, memberships)}

      {:error, _meta} ->
        {:noreply, socket}
    end
  end

  def handle_event("close_team_modal", _params, socket) do
    {:noreply, assign(socket, :selected_team, nil)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.page_container size="narrow" class="py-12">
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
                <tr
                  phx-click="show_team"
                  phx-value-team_id={team.team_id}
                  class={[
                    "border-b border-base-200 transition-colors group hover:bg-base-200/50 cursor-pointer",
                    (index == 1 and not team.is_disqualified) && "bg-primary/5",
                    team.is_disqualified && "opacity-50 grayscale bg-error/5"
                  ]}
                >
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

      <.modal
        id="team-roster-modal"
        show={@selected_team != nil}
        title={@selected_team && @selected_team.team_name}
        on_cancel={JS.push("close_team_modal")}
      >
        <ul class="divide-y divide-base-200 -mx-2">
          <li :for={membership <- @team_members}>
            <.link
              navigate={~p"/profile/#{membership.account_id}"}
              class="flex items-center gap-3 px-2 py-3 hover:bg-base-200/50 rounded-sm transition-colors"
            >
              <.avatar
                src={
                  membership.account && membership.account.profile &&
                    membership.account.profile.avatar_url
                }
                initials={
                  membership.account &&
                    membership.account.login |> String.slice(0, 2) |> String.upcase()
                }
                alt={gettext("Avatar")}
                size="w-9"
              />
              <div class="min-w-0">
                <div class="font-bold text-sm truncate">
                  {membership.account && Identity.display_name(membership.account)}
                </div>
                <div class="text-xs text-base-content/50 truncate">
                  @{membership.account && membership.account.login}
                </div>
              </div>
            </.link>
          </li>
          <li :if={@team_members == []} class="py-6 text-center text-sm text-base-content/40 italic">
            {gettext("No members in this team yet.")}
          </li>
        </ul>
      </.modal>
    </.page_container>
    """
  end
end
