defmodule AthenaWeb.DashboardLive.Index do
  @moduledoc """
  Main dashboard landing page.

  Every account gets the student view: a "continue learning" shortcut,
  enrolled course progress, and upcoming access-window deadlines. Accounts
  that additionally own an `Athena.Learning.Instructor` profile (the
  ground truth for "is this account a teacher" — not a permission or role
  name) also get a Teaching section underneath: the cohorts they manage,
  which members went quiet this week, and — for those who can also grade —
  a pending-review counter. Both layers are gated at the data-loading step
  in `mount/3`, not just in the template.
  """
  use AthenaWeb, :live_view

  alias Athena.{Learning, Content, Identity, Gamification, Announcements}
  alias Athena.Learning.Instructor

  @max_dashboard_competitions 5

  @impl true
  def mount(_params, _session, socket) do
    account = socket.assigns.current_user

    enrollments = Learning.list_student_enrollments(account.id)
    last_activity = Learning.last_activity(account.id)
    total_xp = Gamification.total_xp(account.id)
    streak = Gamification.streak(account.id)

    progress_by_enrollment_id = Learning.course_progress_batch(account.id, enrollments)

    courses =
      Enum.map(enrollments, fn enrollment ->
        %{enrollment: enrollment, progress: Map.fetch!(progress_by_enrollment_id, enrollment.id)}
      end)

    deadlines =
      account.id
      |> Learning.list_upcoming_deadlines()
      |> Enum.map(&resolve_deadline/1)
      |> Enum.reject(&is_nil/1)

    public_competitions = load_public_competitions()
    if connected?(socket), do: subscribe_to_leaderboards(public_competitions)

    {:ok, {announcements, _meta}} = Announcements.list_for_viewer(account, %{"page_size" => 5})

    {:ok,
     socket
     |> assign(:continue, resolve_continue(last_activity, enrollments))
     |> assign(:courses, courses)
     |> assign(:deadlines, deadlines)
     |> assign(:announcements, announcements)
     |> assign(:daily_challenge, resolve_daily_challenge(account.id))
     |> assign(:teaching, build_teaching_section(account))
     |> assign(:total_xp, total_xp)
     |> assign(:level, Gamification.level_for_xp(total_xp))
     |> assign(:streak, streak)
     |> assign(:public_competitions, public_competitions)}
  end

  @impl true
  def handle_info(:update_leaderboard, socket) do
    {:noreply, assign(socket, :public_competitions, load_public_competitions())}
  end

  # The 5 most recently active published competitions - a competition
  # nobody has enrolled a team in yet has nothing to show, so it's dropped
  # rather than padding the list out. `last_activity: nil` on every row
  # (teams enrolled, nobody has submitted anything yet) sorts last.
  defp load_public_competitions do
    Content.list_public_competitions()
    |> Enum.map(fn course ->
      %{course: course, board: Learning.get_team_leaderboard(course.id)}
    end)
    |> Enum.reject(&(&1.board == []))
    |> Enum.sort_by(&latest_activity_unix(&1.board), :desc)
    |> Enum.take(@max_dashboard_competitions)
  end

  # The single leading (non-disqualified) team, for the dashboard's
  # one-line teaser under each competition - `board` is already ranked by
  # `get_team_leaderboard/1`.
  defp leading_team(board) do
    Enum.find(board, &(!&1.is_disqualified))
  end

  defp teams_count(board), do: length(board)

  defp latest_activity_unix(board) do
    board
    |> Enum.map(& &1.last_activity)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> 0
      activities -> activities |> Enum.map(&DateTime.to_unix/1) |> Enum.max()
    end
  end

  defp subscribe_to_leaderboards(public_competitions) do
    Enum.each(public_competitions, fn %{course: course} ->
      Phoenix.PubSub.subscribe(Athena.PubSub, "leaderboard:#{course.id}")
    end)
  end

  defp resolve_daily_challenge(account_id) do
    with %{} = challenge <- Gamification.today_challenge(account_id),
         {:ok, block} <- Content.get_block(challenge.block_id),
         {:ok, section} <- Content.get_section(block.section_id),
         {:ok, course} <- Content.get_course(section.course_id) do
      %{course: course, section_id: section.id, completed?: !is_nil(challenge.completed_at)}
    else
      _ -> nil
    end
  end

  @doc false
  # Teaching data is only built (and only ever shown) for accounts that own an
  # `Instructor` profile — being an instructor is a fact about the account
  # (a row in `instructors`), not a role name, so this is checked here at the
  # data layer rather than left to a permission string alone.
  defp build_teaching_section(account) do
    with %Instructor{} <- Learning.get_instructor_by_account(account.id),
         true <- Identity.can?(account, "cohorts.read") do
      {:ok, {cohorts, _meta}} = Learning.list_cohorts(account, %{"page_size" => 50})

      cohort_rows =
        cohorts
        |> Enum.filter(&(&1.type == :academic))
        |> Enum.map(fn cohort ->
          %{cohort: cohort, quiet_members: quiet_members_with_accounts(cohort.id)}
        end)

      needs_review_count =
        if Identity.can?(account, "grading.read"), do: count_needs_review(account)

      %{cohorts: cohort_rows, needs_review_count: needs_review_count}
    else
      _ -> nil
    end
  end

  defp quiet_members_with_accounts(cohort_id) do
    members = Gamification.quiet_members(cohort_id)
    accounts_map = Identity.get_accounts_map(Enum.map(members, & &1.account_id))

    Enum.map(members, fn member ->
      Map.put(member, :account, Map.get(accounts_map, member.account_id))
    end)
  end

  defp resolve_continue(%{block_id: block_id}, enrollments) do
    resolved =
      with {:ok, block} <- Content.get_block(block_id),
           {:ok, section} <- Content.get_section(block.section_id),
           {:ok, course} <- Content.get_course(section.course_id) do
        %{course: course, section_id: section.id}
      else
        _ -> nil
      end

    resolved || fallback_continue(enrollments)
  end

  defp resolve_continue(nil, enrollments), do: fallback_continue(enrollments)

  defp fallback_continue([]), do: nil
  defp fallback_continue([enrollment | _]), do: %{course: enrollment.course, section_id: nil}

  defp resolve_deadline(%{resource_type: :section} = schedule) do
    case Content.get_section(schedule.resource_id) do
      {:ok, section} -> build_deadline_row(schedule, section.course_id, section.title)
      _ -> nil
    end
  end

  defp resolve_deadline(%{resource_type: :block} = schedule) do
    with {:ok, block} <- Content.get_block(schedule.resource_id),
         {:ok, section} <- Content.get_section(block.section_id) do
      build_deadline_row(schedule, section.course_id, section.title)
    else
      _ -> nil
    end
  end

  defp build_deadline_row(schedule, course_id, section_title) do
    case Content.get_course(course_id) do
      {:ok, course} -> %{lock_at: schedule.lock_at, section_title: section_title, course: course}
      _ -> nil
    end
  end

  defp count_needs_review(account) do
    filters = [%{"field" => "status", "op" => "==", "value" => "needs_review"}]

    case Learning.list_submissions(account, %{"filters" => filters, "page_size" => 1}) do
      {:ok, {_subs, meta}} -> meta.total_count
      _ -> 0
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.page_container size="standard" class="space-y-8">
      <div class="flex items-center justify-between flex-wrap gap-4">
        <h1 class="text-3xl font-display font-black uppercase tracking-tight text-base-content">
          {gettext("Dashboard")}
        </h1>

        <.link
          navigate={~p"/profile/#{@current_user.id}?tab=achievements"}
          class="flex items-center gap-2 px-4 py-2 rounded-sm bg-base-200 hover:bg-base-300 transition-colors"
        >
          <.icon name="hero-star" class="size-4 text-primary" />
          <span class="font-bold text-sm">
            {gettext("Level %{level}", level: @level.level)}
          </span>
          <span class="text-xs text-base-content/50">
            {gettext("%{xp} XP", xp: @total_xp)}
          </span>
          <span
            :if={@streak.current_weeks > 0}
            class="flex items-center gap-1 text-xs font-bold text-warning"
          >
            <.icon name="hero-fire" class="size-4" />
            {@streak.current_weeks}
          </span>
        </.link>
      </div>

      <div :if={@announcements != []} class="card bg-base-100 border border-base-300 rounded-sm">
        <div class="card-body gap-3">
          <div class="flex items-center justify-between">
            <h2 class="font-display font-black uppercase text-sm text-base-content/70 flex items-center gap-2">
              <.icon name="hero-megaphone" class="size-5 text-primary" />
              {gettext("Announcements")}
            </h2>
            <.button variant="ghost" size="xs" navigate={~p"/announcements"}>
              {gettext("View all")}
            </.button>
          </div>

          <div
            :for={announcement <- @announcements}
            class="border-b border-base-200 last:border-0 pb-3 last:pb-0"
          >
            <div class="flex items-center justify-between gap-2">
              <div class="font-bold truncate">{announcement.title}</div>
              <.badge tone={if announcement.scope == :global, do: "primary", else: "neutral"}>
                {if announcement.scope == :global, do: gettext("Global"), else: gettext("Cohort")}
              </.badge>
            </div>
            <p class="text-sm text-base-content/60 line-clamp-2">{announcement.body}</p>
          </div>
        </div>
      </div>

      <div
        :if={@daily_challenge}
        class={[
          "card border rounded-sm",
          @daily_challenge.completed? && "bg-success/10 border-success/30",
          !@daily_challenge.completed? && "bg-base-100 border-base-300"
        ]}
      >
        <div class="card-body flex-row items-center justify-between flex-wrap gap-4">
          <div class="flex items-center gap-3">
            <.icon name="hero-sparkles" class="size-8 text-primary" />
            <div>
              <div class="text-xs font-black uppercase tracking-widest text-base-content/50">
                {gettext("Daily challenge")}
              </div>
              <div class="font-display font-black">{@daily_challenge.course.title}</div>
            </div>
          </div>
          <.badge :if={@daily_challenge.completed?} tone="success" class="gap-1">
            <.icon name="hero-check" class="size-4" />
            {gettext("Solved today")}
          </.badge>
          <.button
            :if={!@daily_challenge.completed?}
            variant="primary"
            size="sm"
            navigate={~p"/daily-challenge"}
          >
            {gettext("Solve")}
            <.icon name="hero-arrow-right" class="size-4" />
          </.button>
        </div>
      </div>

      <div :if={@continue} class="card bg-base-100 border border-base-300 rounded-sm">
        <div class="card-body flex-row items-center justify-between flex-wrap gap-4">
          <div>
            <div class="text-xs font-black uppercase tracking-widest text-base-content/50">
              {gettext("Continue learning")}
            </div>
            <h2 class="text-2xl font-display font-black mt-1">{@continue.course.title}</h2>
          </div>
          <.button variant="primary" navigate={continue_path(@continue)}>
            {gettext("Resume")}
            <.icon name="hero-arrow-right" class="size-5" />
          </.button>
        </div>
      </div>

      <div :if={!@continue} class="card bg-base-100 border border-base-300 rounded-sm">
        <.empty_state
          icon="hero-book-open"
          title={gettext("No courses yet")}
          description={gettext("Once you join a cohort or unlock a course, it will show up here.")}
        />
      </div>

      <div class="grid grid-cols-1 lg:grid-cols-3 gap-8">
        <div class="lg:col-span-2 space-y-4">
          <h2 class="font-display font-black uppercase text-sm text-base-content/70">
            {gettext("My Courses")}
          </h2>

          <div :if={@courses == []} class="text-base-content/50 text-sm">
            {gettext("You're not enrolled in any course yet.")}
          </div>

          <div class="space-y-3">
            <.link
              :for={%{enrollment: enrollment, progress: progress} <- @courses}
              navigate={~p"/learn/courses/#{enrollment.course.id}"}
              class="card bg-base-100 border border-base-300 hover:border-primary/40 transition-colors rounded-sm block"
            >
              <div class="card-body flex-row items-center gap-4 py-4">
                <div
                  class="radial-progress text-primary bg-primary/10 text-[10px] font-bold shrink-0"
                  style={"--value:#{progress.percent}; --size:2.5rem; --thickness: 3px;"}
                  role="progressbar"
                >
                  {progress.percent}%
                </div>
                <div class="min-w-0 flex-1">
                  <div class="font-bold truncate">{enrollment.course.title}</div>
                  <div class="text-xs text-base-content/50">
                    {if enrollment.cohort_id,
                      do: enrollment.cohort.name,
                      else: gettext("Self-paced")}
                  </div>
                </div>
                <.icon name="hero-chevron-right" class="size-5 text-base-content/30 shrink-0" />
              </div>
            </.link>
          </div>
        </div>

        <div class="space-y-4">
          <h2 class="font-display font-black uppercase text-sm text-base-content/70">
            {gettext("Coming Up")}
          </h2>

          <div :if={@deadlines == []} class="text-base-content/50 text-sm">
            {gettext("No upcoming access-window deadlines.")}
          </div>

          <div class="space-y-2">
            <div
              :for={deadline <- @deadlines}
              class="card bg-base-100 border border-base-300 rounded-sm"
            >
              <div class="card-body py-3 px-4">
                <div class="text-xs font-black uppercase text-error tracking-wide">
                  {Calendar.strftime(deadline.lock_at, "%d.%m %H:%M")}
                </div>
                <div class="font-bold text-sm truncate">{deadline.course.title}</div>
                <div class="text-xs text-base-content/50 truncate">{deadline.section_title}</div>
              </div>
            </div>
          </div>
        </div>
      </div>

      <div :if={@public_competitions != []} class="space-y-4">
        <h2 class="font-display font-black uppercase text-sm text-base-content/70">
          {gettext("Competitions")}
        </h2>

        <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
          <.link
            :for={%{course: course, board: board} <- @public_competitions}
            navigate={~p"/learn/courses/#{course.id}/leaderboard"}
            class="card bg-base-100 border border-base-300 hover:border-primary/40 transition-colors rounded-sm block"
          >
            <div class="card-body py-4 gap-2">
              <div class="flex items-center justify-between gap-2">
                <div class="font-bold truncate">{course.title}</div>
                <.icon name="hero-trophy" class="size-5 text-primary shrink-0" />
              </div>

              <div class="text-xs text-base-content/50">
                {ngettext("%{count} team", "%{count} teams", teams_count(board),
                  count: teams_count(board)
                )}
              </div>

              <div :if={leading_team(board)} class="flex items-center justify-between gap-2 text-sm">
                <span class="truncate">🏆 {leading_team(board).team_name}</span>
                <span class="font-mono font-bold text-primary shrink-0">
                  {leading_team(board).total_score}
                </span>
              </div>
            </div>
          </.link>
        </div>
      </div>

      <div :if={@teaching} class="space-y-4 border-t border-base-300 pt-8">
        <h2 class="font-display font-black uppercase text-sm text-base-content/70">
          {gettext("Teaching")}
        </h2>

        <div
          :if={@teaching.needs_review_count}
          class="card bg-warning/10 border border-warning/30 rounded-sm"
        >
          <div class="card-body flex-row items-center justify-between flex-wrap gap-4">
            <div class="flex items-center gap-3">
              <.icon name="hero-academic-cap" class="size-8 text-warning" />
              <div class="font-display font-black text-lg">
                {ngettext(
                  "%{count} submission awaiting review",
                  "%{count} submissions awaiting review",
                  @teaching.needs_review_count,
                  count: @teaching.needs_review_count
                )}
              </div>
            </div>
            <.button variant="warning" size="sm" navigate={~p"/teaching/grading"}>
              {gettext("Go to grading")}
            </.button>
          </div>
        </div>

        <div :if={@teaching.cohorts == []} class="text-base-content/50 text-sm">
          {gettext("You don't manage any cohorts yet.")}
        </div>

        <div :if={@teaching.cohorts != []} class="grid grid-cols-1 md:grid-cols-2 gap-4">
          <div
            :for={row <- @teaching.cohorts}
            class="card bg-base-100 border border-base-300 rounded-sm"
          >
            <div class="card-body py-4 gap-2">
              <div class="flex items-center justify-between">
                <div class="font-bold">{row.cohort.name}</div>
                <.button variant="ghost" size="xs" navigate={~p"/teaching/cohorts/#{row.cohort.id}"}>
                  {gettext("Open")}
                </.button>
              </div>

              <div :if={row.quiet_members == []} class="text-xs text-base-content/50">
                {gettext("Everyone was active this week.")}
              </div>

              <div :if={row.quiet_members != []} class="space-y-1">
                <div class="text-xs font-black uppercase text-base-content/50 tracking-wide">
                  {gettext("Quiet this week")}
                </div>
                <div :for={member <- row.quiet_members} class="text-sm truncate">
                  {member.account && member.account.login}
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </.page_container>
    """
  end

  defp continue_path(%{section_id: nil, course: course}), do: ~p"/learn/courses/#{course.id}"

  defp continue_path(%{section_id: section_id, course: course}),
    do: ~p"/learn/courses/#{course.id}/play/#{section_id}"
end
