defmodule AthenaWeb.TeachingLive.CohortEngagement do
  @moduledoc """
  Live engagement dashboard for teachers - two screens in one LiveView
  (`?view=students|content`, sharing one mount/permission gate rather than
  two routes):

  - **"Course radar"** (`:content`, the default) - the Course Map
    (`AthenaWeb.TeachingLive.CourseMapComponents`, from
    `Athena.Engagement.course_map/3`): every block of the course with the
    cohort's numbers and problem spots, or - through the "Looking at"
    lens - one student's numbers next to the cohort's. The sidebar tree
    narrows it to a section; a block opens its detail view (metrics, weekly
    trend, dwell histogram). The older activity charts live on a lazily
    loaded "Activity" tab (`?tab=activity`).
  - **"Group radar"** (`:students`) - every student's level (who needs
    attention) and the signals behind it, from
    `Athena.Engagement.student_radar/3`, worded by
    `AthenaWeb.TeachingLive.EngagementExplanations` and laid out by
    `AthenaWeb.TeachingLive.GroupRadarComponents`. The period, a level
    filter and the open student card all live in the URL
    (`?view=students&window=7&level=...&student=...`); only a new period
    recomputes anything.

  Metrics recompute (both screens) is debounced (at most once every
  `@refresh_debounce_ms`) rather than run on every incoming PubSub event -
  `Athena.Engagement.Metrics` scans raw events on demand with no cache, so
  recomputing per event would query the database once per event. Only a
  single selected block (on "Course radar") subscribes to live updates at
  all; "Student radar" is a snapshot, refreshed on navigation/period change,
  same as the section-level summary table on "Course radar".
  """
  use AthenaWeb, :live_view

  require Logger

  alias Athena.{Content, Engagement, Identity, Learning}
  alias Athena.Content.Block
  alias AthenaWeb.TeachingLive.ChartConfig
  alias AthenaWeb.TeachingLive.EngagementExplanations, as: Explanations
  import AthenaWeb.TeachingLive.CourseTreeComponents, only: [course_tree_nav: 1]

  import AthenaWeb.TeachingLive.CohortAnalyticsComponents,
    only: [analytics_tabs: 1, gradebook_path: 2, block_index: 1]

  import AthenaWeb.TeachingLive.GroupRadarComponents
  import AthenaWeb.TeachingLive.CourseMapComponents, only: [course_map: 1]

  on_mount {AthenaWeb.Hooks.Permission, "engagement.read"}

  @refresh_debounce_ms 2_000
  @radar_windows ~w(7 30 all)

  @impl true
  def mount(%{"id" => cohort_id, "course_id" => course_id}, _session, socket) do
    user = socket.assigns.current_user

    with {:ok, cohort} <- Learning.get_cohort(user, cohort_id),
         {:ok, course} <- Content.get_course(course_id) do
      tree = Content.get_course_tree(course.id, :all)
      {block_names, block_sections} = block_index(tree)

      {:ok,
       socket
       |> assign(:cohort, cohort)
       |> assign(:course, course)
       |> assign(:tree, tree)
       |> assign(:block_names, block_names)
       |> assign(:block_sections, block_sections)
       |> assign(:students, list_students(cohort.id))
       |> assign(:radar_rows, [])
       |> assign(:radar_group, %{progress_median: nil, score_median: nil})
       |> assign(:radar_loaded_window, nil)
       |> assign(:level_filter, nil)
       |> assign(:selected_student_id, nil)
       |> assign(:methodology_open, false)
       |> assign(:view, :content)
       |> assign(:active_section, nil)
       |> assign(:active_block, nil)
       |> assign(:active_account_id, nil)
       |> assign(:metrics, %{})
       |> assign(:subscribed_topic, nil)
       |> assign(:refresh_scheduled, false)
       |> assign(:radar_window, "7")
       |> assign(:student_radar, [])
       |> assign(:student_radar_loading, false)
       |> assign(:course_charts_loading, false)
       |> assign(:trend_metric, :avg_dwell_seconds)
       |> assign(:trend_data, [])
       |> assign(
         :histogram_chart_config,
         ChartConfig.histogram_config(%{buckets: %{}, bucket_width: 0.0, n: 0}, 1)
       )
       |> assign(:course_window, "7")
       |> assign(:course_tab, :map)
       |> assign(:only_problems, false)
       |> assign(:course_map, nil)
       |> assign(:course_map_key, nil)
       |> assign(:heatmap_config, ChartConfig.heatmap_config([]))
       |> assign(:funnel_chart_config, ChartConfig.funnel_config([]))
       |> assign(:trend_chart_config, ChartConfig.line_config([]))
       |> assign(:correction_rate_chart_config, ChartConfig.correction_rate_config([]))
       |> assign(:page_title, gettext("Engagement: %{course}", course: course.title))}
    else
      _ ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Access denied or course not found."))
         |> push_navigate(to: ~p"/teaching/cohorts")}
    end
  end

  @impl true
  def handle_params(%{"view" => "students"} = params, _url, socket) do
    window = if params["window"] in @radar_windows, do: params["window"], else: "7"

    # Opening a student's card or filtering by level only changes the URL;
    # the radar itself is recomputed only for a new period (or on arrival).
    reload? = socket.assigns.view != :students or socket.assigns.radar_loaded_window != window

    socket =
      socket
      |> resubscribe(nil)
      |> assign(:view, :students)
      |> assign(:radar_window, window)
      |> assign(:level_filter, parse_level(params["level"]))
      |> assign(:selected_student_id, presence(params["student"]))
      |> then(&if(reload?, do: refresh_student_radar(&1), else: &1))

    {:noreply, socket}
  end

  def handle_params(params, _url, socket) do
    section =
      with id when is_binary(id) <- presence(params["section_id"]),
           {:ok, section} <- Content.get_section(id),
           true <- section.course_id == socket.assigns.course.id do
        section
      else
        _ -> nil
      end

    active_block =
      with id when is_binary(id) <- presence(params["block_id"]),
           true <- Map.has_key?(socket.assigns.block_sections, id),
           {:ok, block} <- Content.get_block(id) do
        block
      else
        _ -> nil
      end

    course_window =
      if params["course_window"] in @radar_windows, do: params["course_window"], else: "7"

    socket =
      socket
      |> assign(:view, :content)
      |> assign(:active_section, section)
      |> assign(:active_block, active_block)
      |> assign(:active_account_id, presence(params["account_id"]))
      |> assign(:course_window, course_window)
      |> assign(:course_tab, if(params["tab"] == "activity", do: :activity, else: :map))
      |> assign(:only_problems, params["problems"] == "1")
      |> resubscribe(active_block)
      |> refresh_metrics()
      |> refresh_trend()
      |> refresh_histogram()
      |> refresh_course_view()

    {:noreply, socket}
  end

  # The block detail view needs neither the map nor the charts; the map and
  # the activity charts are each loaded only when their tab is shown.
  defp refresh_course_view(%{assigns: %{active_block: block}} = socket) when not is_nil(block),
    do: socket

  defp refresh_course_view(%{assigns: %{course_tab: :activity}} = socket),
    do: refresh_course_charts(socket)

  defp refresh_course_view(socket), do: refresh_course_map(socket)

  # Recomputed only for a new period or a new student lens - switching
  # sections, toggling "only problems" or coming back from a block reuse it.
  defp refresh_course_map(socket) do
    key = {socket.assigns.course_window, socket.assigns.active_account_id}

    cond do
      not connected?(socket) ->
        socket

      socket.assigns.course_map_key == key and socket.assigns.course_map != nil ->
        socket

      true ->
        cohort_id = socket.assigns.cohort.id
        course_id = socket.assigns.course.id
        since = radar_since(socket.assigns.course_window)
        account_id = socket.assigns.active_account_id

        socket
        |> assign(:course_map, nil)
        |> assign(:course_map_key, key)
        |> cancel_async(:course_map)
        |> start_async(:course_map, fn ->
          Engagement.course_map(cohort_id, course_id, since: since, account_id: account_id)
        end)
    end
  end

  defp parse_level(value) when is_binary(value),
    do: Enum.find(Engagement.assessment_levels(), &(Atom.to_string(&1) == value))

  defp parse_level(_value), do: nil

  defp presence(value) when value in [nil, ""], do: nil
  defp presence(value), do: value

  @impl true
  def handle_event("change_student", %{"account_id" => account_id}, socket) do
    account_id = if account_id == "", do: nil, else: account_id
    {:noreply, push_patch(socket, to: build_path(socket, account_id: account_id))}
  end

  def handle_event("change_window", %{"window" => window}, socket) do
    {:noreply, push_patch(socket, to: radar_path(socket, window))}
  end

  def handle_event("change_course_window", %{"window" => window}, socket) do
    {:noreply, push_patch(socket, to: build_path(socket, course_window: window, block_id: nil))}
  end

  def handle_event("change_trend_metric", %{"metric" => metric}, socket) do
    {:noreply,
     socket |> assign(:trend_metric, String.to_existing_atom(metric)) |> refresh_trend()}
  end

  def handle_event("open_methodology", _params, socket),
    do: {:noreply, assign(socket, :methodology_open, true)}

  def handle_event("close_methodology", _params, socket),
    do: {:noreply, assign(socket, :methodology_open, false)}

  @impl true
  def handle_info({:engagement_event, _event}, socket) do
    if socket.assigns.refresh_scheduled do
      {:noreply, socket}
    else
      Process.send_after(self(), :refresh_metrics, @refresh_debounce_ms)
      {:noreply, assign(socket, :refresh_scheduled, true)}
    end
  end

  def handle_info(:refresh_metrics, socket) do
    {:noreply, socket |> assign(:refresh_scheduled, false) |> refresh_metrics()}
  end

  # Both radars scan a whole course's worth of events, so they are computed
  # off the LiveView process (`start_async/3`) - the page renders immediately
  # with skeletons and fills in when the numbers are ready. A newer request
  # under the same key supersedes an in-flight one (LiveView drops results
  # whose task ref is no longer current), so a fast period/filter switch
  # can't paint stale data.
  @impl true
  def handle_async(:student_radar, {:ok, rows}, socket) do
    radar_rows = radar_rows(rows, socket.assigns.students)

    {:noreply,
     socket
     |> assign(:student_radar, rows)
     |> assign(:radar_rows, radar_rows)
     |> assign(:radar_group, radar_group(radar_rows))
     |> assign(:student_radar_loading, false)}
  end

  def handle_async(:course_overview, {:ok, overview}, socket) do
    {:noreply, socket |> assign_course_charts(overview) |> assign(:course_charts_loading, false)}
  end

  def handle_async(:course_map, {:ok, map}, socket),
    do: {:noreply, assign(socket, :course_map, map)}

  # Loaded on its own - it is the one course chart that can't use rollups,
  # so it must not hold up the others.
  def handle_async(:nudge_rates, {:ok, rates}, socket) do
    rows =
      Enum.map(
        rates,
        &%{label: Explanations.short_label(&1.reason), correction_rate: &1.correction_rate}
      )

    {:noreply,
     assign(socket, :correction_rate_chart_config, ChartConfig.correction_rate_config(rows))}
  end

  def handle_async(key, {:exit, reason}, socket) do
    Logger.error("Engagement dashboard #{key} failed: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(:student_radar_loading, false)
     |> assign(:course_charts_loading, false)
     |> put_flash(:error, gettext("Could not load engagement data. Please try again."))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-[calc(100vh)] lg:h-screen -m-4 sm:-m-6 lg:-m-8 bg-base-100 overflow-hidden">
      <div
        :if={@view == :content}
        class="w-80 shrink-0 border-r border-base-200 flex flex-col bg-base-100 overflow-y-auto"
      >
        <div
          id="course-tree-header"
          class="p-4 border-b border-base-200 bg-base-100 shrink-0 sticky top-0 z-10"
        >
          <.link
            navigate={cohort_show_path(@cohort)}
            class="inline-flex items-center gap-2 text-xs font-bold uppercase tracking-widest text-base-content/50 hover:text-primary transition-colors mb-2"
          >
            <.icon name="hero-arrow-left" class="size-4" />
            {back_to_cohort_label(@cohort)}
          </.link>
          <h2 class="font-black text-lg truncate">{@course.title}</h2>
          <.badge tone="primary" class="mt-1">{@cohort.name}</.badge>
        </div>

        <div class="p-4 space-y-1">
          <.link
            id="map-whole-course"
            patch={build_path(assigns, section_id: nil, block_id: nil)}
            class={[
              "flex items-center gap-2 rounded-sm px-3 py-2 text-sm font-bold transition-colors",
              if(is_nil(@active_section) and is_nil(@active_block),
                do: "bg-primary/10 text-primary",
                else: "hover:bg-base-200"
              )
            ]}
          >
            <.icon name="hero-map" class="size-4" /> {gettext("Whole course")}
          </.link>
          <.course_tree_nav
            sections={@tree}
            active_section_id={if @active_section, do: @active_section.id, else: nil}
            node_path={fn section -> build_path(assigns, section_id: section.id, block_id: nil) end}
            has_badge={fn _section -> false end}
          />
        </div>
      </div>

      <div class="flex-1 overflow-y-auto bg-base-200 p-8 relative">
        <.page_container size="standard">
          <div class="mb-6 flex items-center gap-2">
            <.link
              :if={@view == :students}
              navigate={cohort_show_path(@cohort)}
              class="inline-flex items-center gap-2 text-xs font-bold uppercase tracking-widest text-base-content/50 hover:text-primary transition-colors"
            >
              <.icon name="hero-arrow-left" class="size-4" />
              {back_to_cohort_label(@cohort)}
            </.link>
            <.analytics_tabs
              cohort={@cohort}
              course={@course}
              current_user={@current_user}
              active={@view}
              students_path={radar_path(assigns, @radar_window)}
            />

            <.button
              variant="ghost"
              size="sm"
              navigate={~p"/teaching/courses/#{@course.id}/engagement/compare"}
            >
              <.icon name="hero-chart-bar-square" class="size-4" /> {gettext("Compare Cohorts")}
            </.button>
          </div>

          <%= if @view == :students do %>
            <.group_radar_screen {assigns} />
          <% else %>
            <div class="mb-5 flex flex-wrap items-end justify-between gap-4">
              <div class="min-w-0">
                <h1 class="text-2xl font-black truncate">
                  <%= cond do %>
                    <% @active_block -> %>
                      {Map.get(@block_names, @active_block.id, @active_block.type)}
                    <% @active_section -> %>
                      {@active_section.title}
                    <% true -> %>
                      {gettext("Course map")}
                  <% end %>
                </h1>
                <p :if={!@active_block} class="text-sm text-base-content/60">
                  {gettext("Where in the course the group - or one student - has trouble")}
                </p>
              </div>

              <div class="flex flex-wrap items-center gap-2">
                <form phx-change="change_student" class="flex items-center gap-2">
                  <label for="lens-select" class="text-xs font-bold text-base-content/50">
                    {gettext("Looking at")}
                  </label>
                  <select
                    id="lens-select"
                    name="account_id"
                    class="select select-bordered select-sm rounded-sm max-w-56"
                  >
                    <option value="" selected={is_nil(@active_account_id)}>
                      {gettext("Whole cohort")}
                    </option>
                    <option
                      :for={student <- Enum.reject(@students, &is_nil/1)}
                      value={student.id}
                      selected={@active_account_id == student.id}
                    >
                      {student_name(student)}
                    </option>
                  </select>
                </form>

                <form :if={!@active_block} phx-change="change_course_window">
                  <select
                    id="course-window"
                    name="window"
                    class="select select-bordered select-sm rounded-sm"
                  >
                    <option value="7" selected={@course_window == "7"}>
                      {gettext("Last 7 days")}
                    </option>
                    <option value="30" selected={@course_window == "30"}>
                      {gettext("Last 30 days")}
                    </option>
                    <option value="all" selected={@course_window == "all"}>
                      {gettext("Whole course")}
                    </option>
                  </select>
                </form>
              </div>
            </div>

            <%= if @active_block do %>
              <div class="flex items-center justify-between mb-6">
                <.button variant="ghost" size="sm" patch={build_path(assigns, block_id: nil)}>
                  <.icon name="hero-arrow-left" class="size-4" /> {gettext("Back to course map")}
                </.button>

                <.link
                  :if={
                    Block.gradable?(@active_block) &&
                      Identity.can?(@current_user, "grading.read")
                  }
                  navigate={
                    ~p"/teaching/grading?#{%{"block_id" => @active_block.id, "cohort_id" => @cohort.id}}"
                  }
                  class="btn btn-ghost btn-sm text-primary"
                >
                  <.icon name="hero-inbox-arrow-down" class="size-4" />
                  {gettext("View Submissions")}
                </.link>
              </div>

              <.metrics_table metrics={@metrics} />

              <div class="mt-6 bg-base-100 border border-base-200 rounded-sm p-4">
                <div class="flex items-center justify-between mb-3">
                  <h3 class="text-sm font-black uppercase tracking-widest text-base-content/50">
                    {gettext("Weekly trend")}
                  </h3>
                  <form phx-change="change_trend_metric">
                    <select name="metric" class="select select-bordered select-xs rounded-sm">
                      <option
                        value="avg_dwell_seconds"
                        selected={@trend_metric == :avg_dwell_seconds}
                      >
                        {gettext("Avg dwell (s)")}
                      </option>
                      <option value="sample_size" selected={@trend_metric == :sample_size}>
                        {gettext("Sample size")}
                      </option>
                      <option
                        value="nudge_shown_count"
                        selected={@trend_metric == :nudge_shown_count}
                      >
                        {gettext("Nudges shown")}
                      </option>
                    </select>
                  </form>
                </div>

                <table class="table table-sm">
                  <thead>
                    <tr>
                      <th>{gettext("Week")}</th>
                      <th>{gettext("Value")}</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={point <- @trend_data}>
                      <td>{Date.to_string(point.week)}</td>
                      <td class="font-mono">{format_value(point.value)}</td>
                    </tr>
                    <tr :if={@trend_data == []}>
                      <td colspan="2" class="text-sm text-base-content/40 text-center py-4">
                        {gettext("No data yet.")}
                      </td>
                    </tr>
                  </tbody>
                </table>
              </div>

              <div class="mt-6 bg-base-100 border border-base-200 rounded-sm p-4">
                <h3 class="text-sm font-black uppercase tracking-widest text-base-content/50 mb-1">
                  {gettext("Dwell distribution")}
                </h3>
                <p class="text-xs text-base-content/50 mb-3">
                  {gettext(
                    "The bottom %{percent}% (red) is the cutoff the nudge algorithm reads against.",
                    percent: trunc(Engagement.nudge_percentile_floor())
                  )}
                </p>
                <canvas
                  id="dwell-histogram"
                  phx-hook="EngagementChart"
                  data-config={Jason.encode!(@histogram_chart_config)}
                  class="max-h-72"
                >
                </canvas>
              </div>
            <% else %>
              <div class="mb-4 flex flex-wrap items-center justify-between gap-3">
                <div class="join">
                  <.link
                    id="course-tab-map"
                    patch={build_path(assigns, tab: :map)}
                    class={[
                      "btn btn-sm join-item rounded-sm gap-1.5",
                      if(@course_tab == :map, do: "btn-primary", else: "btn-ghost border-base-300")
                    ]}
                  >
                    <.icon name="hero-map" class="size-4" /> {gettext("Map")}
                  </.link>
                  <.link
                    id="course-tab-activity"
                    patch={build_path(assigns, tab: :activity)}
                    class={[
                      "btn btn-sm join-item rounded-sm gap-1.5",
                      if(@course_tab == :activity,
                        do: "btn-primary",
                        else: "btn-ghost border-base-300"
                      )
                    ]}
                  >
                    <.icon name="hero-chart-bar" class="size-4" /> {gettext("Activity")}
                  </.link>
                </div>

                <.link
                  :if={@course_tab == :map}
                  id="toggle-problems"
                  patch={build_path(assigns, problems: !@only_problems)}
                  class="flex items-center gap-2 text-sm select-none"
                >
                  <input
                    type="checkbox"
                    class="toggle toggle-sm toggle-warning pointer-events-none"
                    checked={@only_problems}
                    tabindex="-1"
                  />
                  {gettext("Only problem spots")}
                </.link>
              </div>

              <%= if @course_tab == :activity do %>
                <.loading_skeleton
                  :if={@course_charts_loading}
                  id="course-charts-loading"
                  rows={4}
                />

                <div :if={!@course_charts_loading} id="course-charts" class="space-y-4 mb-4">
                  <p class="text-sm text-base-content/60">
                    {gettext(
                      "When and how much the group works, how far it gets through each section, and whether nudges help."
                    )}
                  </p>
                  <div class="bg-base-100 border border-base-200 rounded-sm p-4">
                    <h3 class="text-sm font-black uppercase tracking-widest text-base-content/50 mb-3">
                      {gettext("Activity heatmap")}
                    </h3>
                    <canvas
                      id="activity-heatmap"
                      phx-hook="EngagementChart"
                      data-config={Jason.encode!(@heatmap_config)}
                      class="max-h-56"
                    >
                    </canvas>
                  </div>

                  <div class="bg-base-100 border border-base-200 rounded-sm p-4">
                    <h3 class="text-sm font-black uppercase tracking-widest text-base-content/50 mb-3">
                      {gettext("Course funnel")}
                    </h3>
                    <canvas
                      id="course-funnel-chart"
                      phx-hook="EngagementChart"
                      data-config={Jason.encode!(@funnel_chart_config)}
                      class="max-h-56"
                    >
                    </canvas>
                  </div>

                  <div class="bg-base-100 border border-base-200 rounded-sm p-4">
                    <h3 class="text-sm font-black uppercase tracking-widest text-base-content/50 mb-3">
                      {gettext("Nudge correction rate")}
                    </h3>
                    <canvas
                      id="nudge-correction-rate-chart"
                      phx-hook="EngagementChart"
                      data-config={Jason.encode!(@correction_rate_chart_config)}
                      class="max-h-56"
                    >
                    </canvas>
                  </div>

                  <div class="bg-base-100 border border-base-200 rounded-sm p-4">
                    <h3 class="text-sm font-black uppercase tracking-widest text-base-content/50 mb-3">
                      {gettext("Active students")}
                    </h3>
                    <canvas
                      id="active-students-trend"
                      phx-hook="EngagementChart"
                      data-config={Jason.encode!(@trend_chart_config)}
                      class="max-h-56"
                    >
                    </canvas>
                  </div>
                </div>
              <% else %>
                <.loading_skeleton :if={is_nil(@course_map)} id="course-map-loading" rows={6} />
                <.course_map
                  :if={@course_map}
                  map={@course_map}
                  block_names={@block_names}
                  block_path={&build_path(assigns, block_id: &1, section_id: @block_sections[&1])}
                  student={@active_account_id && map_student(@students, @active_account_id)}
                  section_id={@active_section && @active_section.id}
                  only_problems?={@only_problems}
                />
              <% end %>
            <% end %>
          <% end %>
        </.page_container>
      </div>
    </div>
    """
  end

  defp group_radar_screen(assigns) do
    rows =
      if assigns.level_filter,
        do: Enum.filter(assigns.radar_rows, &(&1.level == assigns.level_filter)),
        else: assigns.radar_rows

    selected =
      assigns.selected_student_id &&
        Enum.find(assigns.radar_rows, &(&1.account_id == assigns.selected_student_id))

    assigns =
      assigns
      |> assign(:visible_rows, rows)
      |> assign(:selected, selected)
      |> assign(:counts, Enum.frequencies_by(assigns.radar_rows, & &1.level))

    ~H"""
    <div id="group-radar" class="space-y-4">
      <div class="flex flex-wrap items-end justify-between gap-4">
        <div>
          <h1 class="text-2xl font-black">{gettext("Group Radar")}</h1>
          <p class="text-sm text-base-content/60">
            {gettext("Who needs attention, and why")} · {window_label(@radar_window)}
          </p>
        </div>

        <form phx-change="change_window">
          <select name="window" class="select select-bordered select-sm rounded-sm">
            <option value="7" selected={@radar_window == "7"}>{gettext("Last 7 days")}</option>
            <option value="30" selected={@radar_window == "30"}>{gettext("Last 30 days")}</option>
            <option value="all" selected={@radar_window == "all"}>{gettext("Whole course")}</option>
          </select>
        </form>
      </div>

      <.loading_skeleton :if={@student_radar_loading} id="student-radar-loading" rows={6} />

      <%= if !@student_radar_loading do %>
        <.level_tiles
          counts={@counts}
          active={@level_filter}
          level_path={fn level -> radar_path(assigns, @radar_window, level: level) end}
        />

        <div class="flex flex-wrap items-center justify-between gap-2 rounded-sm bg-base-100 border border-base-200 px-4 py-2.5 text-sm">
          <span class="flex items-center gap-2 text-base-content/70">
            <.icon name="hero-information-circle" class="size-5 text-info shrink-0" />
            {gettext(
              "The status is the first rule that matches: no activity, exam violations, low scores, falling behind, rushing, getting stuck. Click a student to see exactly what counted."
            )}
          </span>
          <button
            id="open-methodology"
            type="button"
            phx-click="open_methodology"
            class="btn btn-ghost btn-xs text-primary"
          >
            {gettext("How is this decided?")}
          </button>
        </div>

        <.radar_table
          rows={@visible_rows}
          filtered?={@level_filter != nil}
          clear_filter_path={radar_path(assigns, @radar_window)}
          student_path={
            fn account_id ->
              radar_path(assigns, @radar_window, level: @level_filter, student: account_id)
            end
          }
        />
      <% end %>

      <.student_drawer
        :if={@selected}
        row={@selected}
        group={@radar_group}
        block_names={@block_names}
        window_label={window_label(@radar_window)}
        close_path={radar_path(assigns, @radar_window, level: @level_filter)}
        course_map_path={
          build_path(assigns, account_id: @selected.account_id, section_id: nil, block_id: nil)
        }
        block_path={
          fn block_id ->
            build_path(assigns,
              account_id: @selected.account_id,
              section_id: Map.get(@block_sections, block_id),
              block_id: block_id
            )
          end
        }
        gradebook_path={
          Identity.can?(@current_user, "grading.read") &&
            gradebook_path(@cohort, @course) <> "?students=#{@selected.account_id}"
        }
      />

      <.methodology_modal show={@methodology_open} />
    </div>
    """
  end

  defp window_label("30"), do: gettext("last 30 days")
  defp window_label("all"), do: gettext("whole course")
  defp window_label(_seven), do: gettext("last 7 days")

  attr :id, :string, required: true
  attr :rows, :integer, default: 4

  defp loading_skeleton(assigns) do
    ~H"""
    <div
      id={@id}
      class="space-y-3 mb-4"
      aria-busy="true"
      aria-label={gettext("Loading engagement data")}
    >
      <div
        :for={i <- 1..@rows}
        class="bg-base-100 border border-base-200 rounded-sm p-4 animate-pulse"
        style={"animation-delay: #{i * 80}ms"}
      >
        <div class="h-3 w-1/4 bg-base-300 rounded-sm mb-3"></div>
        <div class="h-3 w-full bg-base-200 rounded-sm mb-2"></div>
        <div class="h-3 w-2/3 bg-base-200 rounded-sm"></div>
      </div>
    </div>
    """
  end

  defp metrics_table(assigns) do
    assigns = assign_new(assigns, :compact, fn -> false end)

    ~H"""
    <div class={["grid gap-2", (@compact && "grid-cols-3") || "grid-cols-2 md:grid-cols-3"]}>
      <div :for={{key, value} <- Enum.sort(@metrics)} class="bg-base-200/50 rounded-sm p-2">
        <div class="text-[10px] uppercase tracking-widest font-black text-base-content/50">
          {Explanations.metric_label(key)}
        </div>
        <div class="font-mono text-sm">{format_value(value)}</div>
      </div>
      <div :if={@metrics == %{}} class="text-sm text-base-content/40 col-span-full">
        {gettext("No activity recorded yet.")}
      </div>
    </div>
    """
  end

  defp format_value(nil), do: "–"
  defp format_value(true), do: gettext("Yes")
  defp format_value(false), do: gettext("No")
  defp format_value(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 2)
  defp format_value(value), do: to_string(value)

  defp list_students(cohort_id) do
    case Learning.list_cohort_memberships(cohort_id, %{limit: 500}) do
      {:ok, {memberships, _meta}} -> Enum.map(memberships, & &1.account)
      _ -> []
    end
  end

  # Course Radar links. `section_id`, `block_id` and `account_id` are always
  # in the query (existing deep links rely on that shape); the period, tab
  # and "only problems" switch are appended only when not at their default.
  defp build_path(assigns_or_socket, overrides) do
    assigns = assigns_of(assigns_or_socket)

    current = %{
      section_id: assigns.active_section && assigns.active_section.id,
      block_id: assigns.active_block && assigns.active_block.id,
      account_id: assigns.active_account_id,
      course_window: Map.get(assigns, :course_window, "7"),
      tab: Map.get(assigns, :course_tab, :map),
      problems: Map.get(assigns, :only_problems, false)
    }

    v = Map.merge(current, Map.new(overrides))

    extras =
      [
        course_window: v.course_window != "7" && v.course_window,
        tab: v.tab == :activity && "activity",
        problems: v.problems && "1"
      ]
      |> Enum.filter(fn {_key, value} -> value end)

    base =
      build_path(
        assigns.cohort,
        assigns.course,
        v.section_id || "",
        v.block_id || "",
        v.account_id || ""
      )

    if extras == [], do: base, else: base <> "&" <> URI.encode_query(extras)
  end

  defp assigns_of(%{assigns: assigns}), do: assigns
  defp assigns_of(assigns), do: assigns

  # `CohortEngagement` is mounted from both `/teaching/cohorts/:id/
  # engagement/...` (academic) and `/teaching/teams/:id/engagement/...`
  # (team) routes, so every link/patch built here must stay on whichever
  # side the loaded `@cohort.type` belongs to. Each pair of clauses below
  # keeps the exact same query-string shape as before the split (rather
  # than a single generic helper that would reorder params via keyword-list
  # encoding) so existing deep-links/tests keep matching byte-for-byte.
  defp cohort_show_path(%{type: :team, id: id}), do: ~p"/teaching/teams/#{id}"
  defp cohort_show_path(%{id: id}), do: ~p"/teaching/cohorts/#{id}"

  defp back_to_cohort_label(%{type: :team}), do: gettext("Back to Team")
  defp back_to_cohort_label(_cohort), do: gettext("Back to Cohort")

  defp build_path(%{type: :team, id: id}, course, section_id, block_id, account_id) do
    ~p"/teaching/teams/#{id}/engagement/#{course.id}?section_id=#{section_id}&block_id=#{block_id}&account_id=#{account_id}"
  end

  defp build_path(%{id: id}, course, section_id, block_id, account_id) do
    ~p"/teaching/cohorts/#{id}/engagement/#{course.id}?section_id=#{section_id}&block_id=#{block_id}&account_id=#{account_id}"
  end

  defp path_context(%{assigns: assigns}), do: path_context(assigns)

  defp path_context(assigns) do
    {
      assigns.cohort,
      assigns.course,
      assigns.active_section && assigns.active_section.id,
      assigns.active_block && assigns.active_block.id,
      assigns.active_account_id
    }
  end

  defp resubscribe(socket, nil) do
    unsubscribe_current(socket)
    assign(socket, :subscribed_topic, nil)
  end

  defp resubscribe(socket, block) do
    topic = "engagement:#{socket.assigns.cohort.id}:#{block.id}"

    if socket.assigns.subscribed_topic == topic do
      socket
    else
      unsubscribe_current(socket)
      if connected?(socket), do: Phoenix.PubSub.subscribe(Athena.PubSub, topic)
      assign(socket, :subscribed_topic, topic)
    end
  end

  defp unsubscribe_current(%{assigns: %{subscribed_topic: nil}}), do: :ok

  defp unsubscribe_current(%{assigns: %{subscribed_topic: topic}}),
    do: Phoenix.PubSub.unsubscribe(Athena.PubSub, topic)

  defp refresh_trend(%{assigns: %{active_block: nil}} = socket),
    do: assign(socket, :trend_data, [])

  defp refresh_trend(socket) do
    data =
      Engagement.time_series(
        socket.assigns.active_block.id,
        socket.assigns.cohort.id,
        socket.assigns.trend_metric
      )

    assign(socket, :trend_data, data)
  end

  defp refresh_histogram(%{assigns: %{active_block: nil}} = socket) do
    assign(
      socket,
      :histogram_chart_config,
      ChartConfig.histogram_config(%{buckets: %{}, bucket_width: 0.0, n: 0}, 1)
    )
  end

  defp refresh_histogram(socket) do
    histogram = Engagement.histogram(socket.assigns.cohort.id, socket.assigns.active_block.id)
    config = ChartConfig.histogram_config(histogram, histogram_bucket_count())
    assign(socket, :histogram_chart_config, config)
  end

  defp histogram_bucket_count do
    Keyword.get(Application.get_env(:athena, Athena.Engagement, []), :histogram_buckets, 10)
  end

  # Not started on the dead (disconnected) render - that render is thrown
  # away as soon as the socket connects, so computing the radar there just
  # doubled the cost of every page load.
  defp refresh_student_radar(socket) do
    if connected?(socket) do
      since = radar_since(socket.assigns.radar_window)
      cohort_id = socket.assigns.cohort.id
      course_id = socket.assigns.course.id

      socket
      |> assign(:student_radar_loading, true)
      |> assign(:radar_loaded_window, socket.assigns.radar_window)
      |> cancel_async(:student_radar)
      |> start_async(:student_radar, fn ->
        Engagement.student_radar(cohort_id, course_id, since: since)
      end)
    else
      assign(socket, :student_radar_loading, true)
    end
  end

  defp radar_since("30"), do: Engagement.window_start(30)
  defp radar_since("all"), do: nil
  defp radar_since(_seven_or_unknown), do: Engagement.window_start(7)

  # `opts`: `:level` (a level filter) and `:student` (whose card is open).
  defp radar_path(assigns_or_socket, window, opts \\ []) do
    {cohort, course, _section, _block, _account} = path_context(assigns_or_socket)

    query =
      [view: "students", window: window, level: opts[:level], student: opts[:student]]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> URI.encode_query()

    radar_base_path(cohort, course) <> "?" <> query
  end

  defp radar_base_path(%{type: :team, id: id}, course),
    do: ~p"/teaching/teams/#{id}/engagement/#{course.id}"

  defp radar_base_path(%{id: id}, course), do: ~p"/teaching/cohorts/#{id}/engagement/#{course.id}"

  defp refresh_course_charts(socket) do
    if connected?(socket) do
      since = radar_since(socket.assigns.course_window)
      cohort_id = socket.assigns.cohort.id
      course_id = socket.assigns.course.id

      socket
      |> assign(:course_charts_loading, true)
      |> cancel_async(:course_overview)
      |> start_async(:course_overview, fn ->
        Engagement.course_overview(cohort_id, course_id, since: since, include_nudges: false)
      end)
      |> cancel_async(:nudge_rates)
      |> start_async(:nudge_rates, fn ->
        Engagement.nudge_correction_rate(cohort_id, course_id, since: since)
      end)
    else
      assign(socket, :course_charts_loading, true)
    end
  end

  defp assign_course_charts(socket, overview) do
    funnel_rows =
      Enum.map(overview.course_funnel, fn row ->
        %{
          label: row.section_title,
          opened: row.opened,
          interacted: row.interacted,
          completed: row.completed
        }
      end)

    trend_points =
      Enum.map(overview.active_students_trend, fn row ->
        %{date: row.date, value: row.active_count}
      end)

    socket
    |> assign(:heatmap_config, ChartConfig.heatmap_config(overview.activity_heatmap))
    |> assign(:funnel_chart_config, ChartConfig.funnel_config(funnel_rows))
    |> assign(
      :trend_chart_config,
      ChartConfig.line_config(trend_points)
    )
  end

  @level_order Engagement.assessment_levels()

  # Radar rows with display names, most urgent first, then by how much
  # counted, then alphabetically.
  defp radar_rows(rows, students) do
    accounts = Map.new(Enum.reject(students, &is_nil/1), &{&1.id, &1})

    rows
    |> Enum.map(fn row ->
      account = Map.get(accounts, row.account_id)

      Map.merge(row, %{
        name: (account && student_name(account)) || row.account_id,
        login: (account && account.login) || row.account_id
      })
    end)
    |> Enum.sort_by(fn row ->
      {Enum.find_index(@level_order, &(&1 == row.level)), -length(row.signals),
       String.downcase(row.name)}
    end)
  end

  defp map_student(students, account_id) do
    case Enum.find(students, &(&1 && &1.id == account_id)) do
      nil -> %{id: account_id, name: account_id}
      account -> %{id: account.id, name: student_name(account)}
    end
  end

  defp student_name(account) do
    case Identity.display_name(account) do
      name when name in [nil, ""] -> account.login
      name -> name
    end
  end

  defp radar_group(rows) do
    %{
      progress_median: median(Enum.map(rows, & &1.progress_percent)),
      score_median: rows |> Enum.map(& &1.average_score) |> Enum.reject(&is_nil/1) |> median()
    }
  end

  defp median([]), do: nil

  defp median(values) do
    sorted = Enum.sort(values)
    count = length(sorted)
    middle = div(count, 2)

    if rem(count, 2) == 1,
      do: Enum.at(sorted, middle),
      else: (Enum.at(sorted, middle - 1) + Enum.at(sorted, middle)) / 2
  end

  defp refresh_metrics(socket) do
    scope = %{cohort_id: socket.assigns.cohort.id, account_id: socket.assigns.active_account_id}

    metrics =
      cond do
        socket.assigns.active_block ->
          Engagement.get_metrics(
            Map.merge(scope, %{resource_type: :block, resource_id: socket.assigns.active_block.id})
          )

        true ->
          %{}
      end

    assign(socket, :metrics, metrics)
  end
end
