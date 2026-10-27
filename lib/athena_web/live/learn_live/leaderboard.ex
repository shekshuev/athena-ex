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

  import AthenaWeb.LeaderboardComponents

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
       |> assign(:team_members, [])
       |> assign(:member_cohorts, %{})}
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
        member_cohorts =
          memberships
          |> Enum.map(& &1.account_id)
          |> Learning.academic_cohort_names_by_account()

        {:noreply,
         socket
         |> assign(:selected_team, team)
         |> assign(:team_members, memberships)
         |> assign(:member_cohorts, member_cohorts)}

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
        <.board_table id="leaderboard-table" board={@board} row_click="show_team" />
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
                <div
                  :if={Map.get(@member_cohorts, membership.account_id, []) != []}
                  class="flex flex-wrap gap-1 mt-1"
                >
                  <span
                    :for={name <- Map.get(@member_cohorts, membership.account_id, [])}
                    class="badge badge-ghost badge-sm font-medium"
                  >
                    {name}
                  </span>
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
