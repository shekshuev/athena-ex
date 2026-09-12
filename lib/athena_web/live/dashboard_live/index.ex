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

  alias Athena.{Learning, Content, Identity, Gamification}
  alias Athena.Learning.Instructor

  @impl true
  def mount(_params, _session, socket) do
    account = socket.assigns.current_user

    enrollments = Learning.list_student_enrollments(account.id)
    last_activity = Learning.last_activity(account.id)
    total_xp = Gamification.total_xp(account.id)
    streak = Gamification.streak(account.id)

    courses =
      Enum.map(enrollments, fn enrollment ->
        progress =
          Learning.course_progress(account.id, enrollment.course_id, team_id(enrollment))

        %{enrollment: enrollment, progress: progress}
      end)

    deadlines =
      account.id
      |> Learning.list_upcoming_deadlines()
      |> Enum.map(&resolve_deadline/1)
      |> Enum.reject(&is_nil/1)

    {:ok,
     socket
     |> assign(:continue, resolve_continue(last_activity, enrollments))
     |> assign(:courses, courses)
     |> assign(:deadlines, deadlines)
     |> assign(:daily_challenge, resolve_daily_challenge(account.id))
     |> assign(:teaching, build_teaching_section(account))
     |> assign(:total_xp, total_xp)
     |> assign(:level, Gamification.level_for_xp(total_xp))
     |> assign(:streak, streak)}
  end

  # `Progress.course_progress/3`'s cohort_id argument means "team" (a
  # `:team`-type competition cohort — progress there is shared across the
  # whole team, see `Athena.Learning.Progress.count_completed/3`), never an
  # academic class. `Enrollment.cohort_id` is set for both cohort types, so
  # this mirrors the same derivation `LearnLive.Player` already uses.
  defp team_id(%{cohort_id: nil}), do: nil
  defp team_id(%{cohort: %{type: :team}, cohort_id: cohort_id}), do: cohort_id
  defp team_id(_enrollment), do: nil

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
    <div class="max-w-6xl mx-auto space-y-8">
      <div class="flex items-center justify-between flex-wrap gap-4">
        <h1 class="text-3xl font-display font-black uppercase tracking-tight text-base-content">
          {gettext("Dashboard")}
        </h1>

        <.link
          navigate={~p"/me?tab=achievements"}
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
          <span :if={@daily_challenge.completed?} class="badge badge-success gap-1">
            <.icon name="hero-check" class="size-4" />
            {gettext("Solved today")}
          </span>
          <.link
            :if={!@daily_challenge.completed?}
            navigate={
              ~p"/learn/courses/#{@daily_challenge.course.id}/play/#{@daily_challenge.section_id}"
            }
            class="btn btn-primary btn-sm"
          >
            {gettext("Solve")}
            <.icon name="hero-arrow-right" class="size-4" />
          </.link>
        </div>
      </div>

      <div :if={@continue} class="card bg-primary text-primary-content rounded-sm overflow-hidden">
        <div class="card-body flex-row items-center justify-between flex-wrap gap-4">
          <div>
            <div class="text-xs font-black uppercase tracking-widest opacity-70">
              {gettext("Continue learning")}
            </div>
            <h2 class="text-2xl font-display font-black mt-1">{@continue.course.title}</h2>
          </div>
          <.link
            navigate={continue_path(@continue)}
            class="btn btn-lg bg-primary-content text-primary hover:bg-primary-content/90 border-0"
          >
            {gettext("Resume")}
            <.icon name="hero-arrow-right" class="size-5" />
          </.link>
        </div>
      </div>

      <div :if={!@continue} class="card bg-base-100 border border-base-300 rounded-sm">
        <div class="card-body text-center py-12">
          <.icon name="hero-book-open" class="size-12 text-base-content/20 mx-auto mb-4" />
          <h3 class="font-display font-bold text-lg">{gettext("No courses yet")}</h3>
          <p class="text-base-content/60 mt-1">
            {gettext("Once you join a cohort or unlock a course, it will show up here.")}
          </p>
        </div>
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
                  style={"--value:#{progress.percent}; --size:2.75rem; --thickness: 3px;"}
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
            <.link navigate={~p"/teaching/grading"} class="btn btn-warning btn-sm">
              {gettext("Go to grading")}
            </.link>
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
                <.link navigate={~p"/teaching/cohorts/#{row.cohort.id}"} class="btn btn-ghost btn-xs">
                  {gettext("Open")}
                </.link>
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
    </div>
    """
  end

  defp continue_path(%{section_id: nil, course: course}), do: ~p"/learn/courses/#{course.id}"

  defp continue_path(%{section_id: section_id, course: course}),
    do: ~p"/learn/courses/#{course.id}/play/#{section_id}"
end
