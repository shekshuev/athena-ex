defmodule AthenaWeb.TeachingLive.CohortEngagement do
  @moduledoc """
  Live engagement dashboard for teachers - two screens in one LiveView
  (`?view=students|content`, sharing one mount/permission gate rather than
  two routes):

  - **"Course radar"** (`:content`, the default) - mirrors `AthenaWeb.
    TeachingLive.CohortAccess`'s navigation (cohort → course → tree, same
    shared `CourseTreeComponents.course_tree_nav/1`), but the right-hand
    panel shows `Athena.Engagement.Metrics` numbers instead of an
    access-override form, with a student filter above it (default: whole
    cohort).
  - **"Student radar"** (`:students`) - one row per student in the cohort,
    from `Athena.Engagement.student_radar/3`: a slacking index, a
    struggling index, and a color-coded status, windowed by a period picker
    (default: last 7 days) so a teacher can actually see whether behavior
    changes after they step in, not just a lifetime total.

  Metrics recompute (both screens) is debounced (at most once every
  `@refresh_debounce_ms`) rather than run on every incoming PubSub event -
  `Athena.Engagement.Metrics` scans raw events on demand with no cache, so
  recomputing per event would query the database once per event. Only a
  single selected block (on "Course radar") subscribes to live updates at
  all; "Student radar" is a snapshot, refreshed on navigation/period change,
  same as the section-level summary table on "Course radar".
  """
  use AthenaWeb, :live_view

  alias Athena.{Content, Engagement, Learning}
  alias AthenaWeb.TeachingLive.ChartConfig
  import AthenaWeb.TeachingLive.CourseTreeComponents, only: [course_tree_nav: 1]

  on_mount {AthenaWeb.Hooks.Permission, "engagement.read"}

  @refresh_debounce_ms 2_000
  @radar_windows ~w(7 30 all)

  @impl true
  def mount(%{"id" => cohort_id, "course_id" => course_id}, _session, socket) do
    user = socket.assigns.current_user

    with {:ok, cohort} <- Learning.get_cohort(user, cohort_id),
         {:ok, course} <- Content.get_course(course_id) do
      tree = Content.get_course_tree(course.id, :all)

      {:ok,
       socket
       |> assign(:cohort, cohort)
       |> assign(:course, course)
       |> assign(:tree, tree)
       |> assign(:students, list_students(cohort.id))
       |> assign(:view, :content)
       |> assign(:active_section, nil)
       |> assign(:blocks, [])
       |> assign(:active_block, nil)
       |> assign(:active_account_id, nil)
       |> assign(:metrics, %{})
       |> assign(:subscribed_topic, nil)
       |> assign(:refresh_scheduled, false)
       |> assign(:radar_window, "7")
       |> assign(:student_radar, [])
       |> assign(:trend_metric, :avg_dwell_seconds)
       |> assign(:trend_data, [])
       |> assign(
         :histogram_chart_config,
         ChartConfig.histogram_config(%{buckets: %{}, bucket_width: 0.0, n: 0}, 1)
       )
       |> assign(:course_window, "7")
       |> assign(:section_chart_config, ChartConfig.stacked_bar_config([]))
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
         |> push_navigate(to: ~p"/teaching/cohorts/#{cohort_id}")}
    end
  end

  @impl true
  def handle_params(%{"view" => "students"} = params, _url, socket) do
    window = if params["window"] in @radar_windows, do: params["window"], else: "7"

    socket =
      socket
      |> resubscribe(nil)
      |> assign(:view, :students)
      |> assign(:radar_window, window)
      |> refresh_student_radar()

    {:noreply, socket}
  end

  def handle_params(params, _url, socket) do
    section_id =
      if params["section_id"] in [nil, ""],
        do: get_first_section_id(socket.assigns.tree),
        else: params["section_id"]

    account_id = params["account_id"] || nil
    account_id = if account_id in [nil, ""], do: nil, else: account_id

    course_window =
      if params["course_window"] in @radar_windows, do: params["course_window"], else: "7"

    if section_id do
      {:ok, section} = Content.get_section(section_id)
      blocks = section_id |> Content.list_blocks_by_section(:all) |> Enum.sort_by(& &1.order)

      active_block =
        if params["block_id"], do: Enum.find(blocks, &(&1.id == params["block_id"])), else: nil

      socket =
        socket
        |> assign(:view, :content)
        |> assign(:active_section, section)
        |> assign(:blocks, blocks)
        |> assign(:active_block, active_block)
        |> assign(:active_account_id, account_id)
        |> assign(:course_window, course_window)
        |> resubscribe(active_block)
        |> refresh_metrics()
        |> refresh_trend()
        |> refresh_histogram()
        |> refresh_course_charts()

      {:noreply, socket}
    else
      {:noreply, assign(socket, :view, :content)}
    end
  end

  @impl true
  def handle_event("change_student", %{"account_id" => account_id}, socket) do
    account_id = if account_id == "", do: nil, else: account_id
    {:noreply, push_patch(socket, to: build_path(socket, account_id: account_id))}
  end

  def handle_event("change_window", %{"window" => window}, socket) do
    {:noreply, push_patch(socket, to: radar_path(socket, window))}
  end

  def handle_event("change_course_window", %{"window" => window}, socket) do
    {:noreply, push_patch(socket, to: course_charts_path(socket, window))}
  end

  def handle_event("change_trend_metric", %{"metric" => metric}, socket) do
    {:noreply,
     socket |> assign(:trend_metric, String.to_existing_atom(metric)) |> refresh_trend()}
  end

  def handle_event(
        "chart_point_click",
        %{"chart" => "student-radar-scatter", "index" => index},
        socket
      ) do
    case Enum.at(socket.assigns.student_radar, index) do
      nil -> {:noreply, socket}
      row -> {:noreply, push_patch(socket, to: student_detail_path(socket.assigns, row))}
    end
  end

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

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-[calc(100vh)] lg:h-screen -m-4 sm:-m-6 lg:-m-8 bg-base-100 overflow-hidden">
      <div
        :if={@view == :content}
        class="w-80 shrink-0 border-r border-base-200 flex flex-col bg-base-100 overflow-y-auto"
      >
        <div class="p-4 border-b border-base-200 bg-base-50 shrink-0">
          <.link
            navigate={~p"/teaching/cohorts/#{@cohort.id}"}
            class="inline-flex items-center gap-2 text-xs font-bold uppercase tracking-widest text-base-content/50 hover:text-primary transition-colors mb-2"
          >
            <.icon name="hero-arrow-left" class="size-4" />
            {gettext("Back to Cohort")}
          </.link>
          <h2 class="font-black text-lg truncate">{@course.title}</h2>
          <div class="badge badge-primary rounded-sm badge-outline mt-1 font-bold">
            {@cohort.name}
          </div>
        </div>

        <div class="p-4 space-y-1">
          <.course_tree_nav
            sections={@tree}
            active_section_id={if @active_section, do: @active_section.id, else: nil}
            node_path={fn section -> build_path(assigns, section_id: section.id, block_id: nil) end}
            has_badge={fn _section -> false end}
          />
        </div>
      </div>

      <div class="flex-1 overflow-y-auto bg-base-200 p-8 relative">
        <div class="max-w-6xl mx-auto">
          <div class="mb-6 flex items-center gap-2">
            <.link
              :if={@view == :students}
              navigate={~p"/teaching/cohorts/#{@cohort.id}"}
              class="inline-flex items-center gap-2 text-xs font-bold uppercase tracking-widest text-base-content/50 hover:text-primary transition-colors"
            >
              <.icon name="hero-arrow-left" class="size-4" />
              {gettext("Back to Cohort")}
            </.link>
            <div class="join">
              <.link
                patch={radar_path(assigns, @radar_window)}
                class={["btn btn-sm join-item rounded-sm", @view == :students && "btn-primary"]}
              >
                {gettext("Group Radar")}
              </.link>
              <.link
                patch={content_view_path(assigns)}
                class={["btn btn-sm join-item rounded-sm", @view == :content && "btn-primary"]}
              >
                {gettext("Course Radar")}
              </.link>
            </div>

            <.link
              navigate={~p"/teaching/courses/#{@course.id}/engagement/compare"}
              class="btn btn-ghost btn-sm rounded-sm"
            >
              <.icon name="hero-chart-bar-square" class="size-4" /> {gettext("Compare Cohorts")}
            </.link>
          </div>

          <%= if @view == :students do %>
            <.student_radar_screen
              students={@students}
              rows={@student_radar}
              window={@radar_window}
              student_link={fn row -> student_detail_path(assigns, row) end}
            />
          <% else %>
            <div class="mb-6 flex items-center justify-between gap-4">
              <h1 class="text-2xl font-black truncate">
                {if @active_block,
                  do: @active_block.type,
                  else: @active_section && @active_section.title}
              </h1>

              <form phx-change="change_student">
                <select name="account_id" class="select select-bordered select-sm rounded-sm">
                  <option value="" selected={is_nil(@active_account_id)}>
                    {gettext("Whole cohort")}
                  </option>
                  <option
                    :for={student <- @students}
                    value={student && student.id}
                    selected={@active_account_id == (student && student.id)}
                  >
                    {student && student.login}
                  </option>
                </select>
              </form>

              <.link
                href={~p"/teaching/cohorts/#{@cohort.id}/engagement/#{@course.id}/export.csv"}
                class="btn btn-ghost btn-sm rounded-sm"
              >
                <.icon name="hero-arrow-down-tray" class="size-4" /> {gettext("Export CSV")}
              </.link>
            </div>

            <%= if @active_block do %>
              <.link
                patch={build_path(assigns, block_id: nil)}
                class="btn btn-ghost rounded-sm btn-sm mb-6"
              >
                <.icon name="hero-arrow-left" class="size-4" /> {gettext("Back to Section")}
              </.link>

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
              <div class="flex items-center justify-between mb-3">
                <h3 class="text-xs font-black uppercase tracking-widest text-base-content/50">
                  {gettext("Charts period")}
                </h3>
                <form phx-change="change_course_window">
                  <select name="window" class="select select-bordered select-xs rounded-sm">
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

              <div class="grid grid-cols-1 lg:grid-cols-4 gap-4 mb-4">
                <div class="bg-base-100 border border-base-200 rounded-sm p-4">
                  <h3 class="text-sm font-black uppercase tracking-widest text-base-content/50 mb-3">
                    {gettext("Flags per section")}
                  </h3>
                  <canvas
                    id="section-flag-stacked-bar"
                    phx-hook="EngagementChart"
                    data-config={Jason.encode!(@section_chart_config)}
                    class="max-h-72"
                  >
                  </canvas>
                </div>

                <div class="bg-base-100 border border-base-200 rounded-sm p-4">
                  <h3 class="text-sm font-black uppercase tracking-widest text-base-content/50 mb-3">
                    {gettext("Activity heatmap")}
                  </h3>
                  <canvas
                    id="activity-heatmap"
                    phx-hook="EngagementChart"
                    data-config={Jason.encode!(@heatmap_config)}
                    class="max-h-72"
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
                    class="max-h-72"
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
                    class="max-h-72"
                  >
                  </canvas>
                </div>
              </div>

              <div class="bg-base-100 border border-base-200 rounded-sm p-4 mb-4">
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

              <div class="space-y-4">
                <div
                  :for={block <- sorted_blocks(@blocks, @metrics)}
                  class="bg-base-100 border border-base-200 rounded-sm p-4"
                >
                  <div class="flex items-center justify-between mb-2">
                    <div class="flex items-center gap-2">
                      <div class="text-sm font-bold">{block.type}</div>
                      <div
                        :if={content_flags_for(Map.get(@metrics, block.id, %{})) != []}
                        class="badge badge-warning badge-sm rounded-sm gap-1"
                        title={Enum.join(content_flags_for(Map.get(@metrics, block.id, %{})), ", ")}
                      >
                        <.icon name="hero-exclamation-triangle" class="size-3" />
                        {gettext("Content issue")}
                      </div>
                    </div>
                    <.link
                      patch={build_path(assigns, block_id: block.id)}
                      class="btn btn-ghost btn-xs text-primary"
                    >
                      {gettext("View metrics")}
                      <.icon name="hero-arrow-right" class="size-4" />
                    </.link>
                  </div>
                  <.metrics_table metrics={Map.get(@metrics, block.id, %{})} compact={true} />
                </div>
              </div>
            <% end %>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp student_radar_screen(assigns) do
    ~H"""
    <div>
      <div class="mb-4 flex items-center justify-between gap-4">
        <h1 class="text-2xl font-black">{gettext("Group Radar")}</h1>

        <form phx-change="change_window">
          <select name="window" class="select select-bordered select-sm rounded-sm">
            <option value="7" selected={@window == "7"}>{gettext("Last 7 days")}</option>
            <option value="30" selected={@window == "30"}>{gettext("Last 30 days")}</option>
            <option value="all" selected={@window == "all"}>{gettext("Whole course")}</option>
          </select>
        </form>
      </div>

      <div class="bg-base-100 border border-base-200 rounded-sm p-4 mb-4">
        <h2 class="text-xs font-black uppercase tracking-widest text-base-content/50 mb-2">
          {gettext("Slacking vs. struggling")}
        </h2>
        <canvas
          id="student-radar-scatter"
          phx-hook="EngagementChart"
          data-clickable="true"
          data-config={Jason.encode!(student_scatter_config(@rows, @students))}
          class="max-h-72"
        >
        </canvas>
      </div>

      <div class="overflow-x-auto bg-base-100 border border-base-200 rounded-sm">
        <table class="table">
          <thead>
            <tr>
              <th>{gettext("Student")}</th>
              <th>{gettext("Progress")}</th>
              <th>{gettext("Slacking index")}</th>
              <th>{gettext("Struggling index")}</th>
              <th>{gettext("Status")}</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @rows}>
              <td>
                <.link patch={@student_link.(row)} class="link link-primary font-bold">
                  {student_login(@students, row.account_id)}
                </.link>
              </td>
              <td class="font-mono">{format_value(row.progress_percent)}%</td>
              <td class="font-mono">{row.slacking_index}</td>
              <td class="font-mono">{row.struggling_index}</td>
              <td>{status_badge(assigns, row.status)}</td>
            </tr>
            <tr :if={@rows == []}>
              <td colspan="5" class="text-sm text-base-content/40 text-center py-6">
                {gettext("No students in this cohort yet.")}
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  defp status_badge(assigns, status) do
    assigns = assign(assigns, :status, status)

    ~H"""
    <span class={["badge rounded-sm font-bold", status_badge_class(@status)]}>
      {status_label(@status)}
    </span>
    """
  end

  defp status_badge_class(:red), do: "badge-error"
  defp status_badge_class(:yellow), do: "badge-warning"
  defp status_badge_class(:green), do: "badge-success"

  defp status_label(:red), do: gettext("Needs attention")
  defp status_label(:yellow), do: gettext("Struggling")
  defp status_label(:green), do: gettext("On track")

  defp student_login(students, account_id) do
    case Enum.find(students, &(&1 && &1.id == account_id)) do
      %{login: login} -> login
      _ -> account_id
    end
  end

  # `index` in the `chart_point_click` payload is this list's position, so
  # this must iterate `rows` in the exact same order the table above it
  # does - no sorting/filtering here that isn't mirrored there too.
  defp student_scatter_config(rows, students) do
    points =
      Enum.map(rows, fn row ->
        %{
          x: row.slacking_index,
          y: row.struggling_index,
          label: student_login(students, row.account_id)
        }
      end)

    ChartConfig.scatter_config(points, x_label: "Slacking index", y_label: "Struggling index")
  end

  defp metrics_table(assigns) do
    assigns = assign_new(assigns, :compact, fn -> false end)

    ~H"""
    <div class={["grid gap-2", (@compact && "grid-cols-3") || "grid-cols-2 md:grid-cols-3"]}>
      <div :for={{key, value} <- Enum.sort(@metrics)} class="bg-base-200/50 rounded-sm p-2">
        <div class="text-[10px] uppercase tracking-widest font-black text-base-content/50">
          {humanize_key(key)}
        </div>
        <div class="font-mono text-sm">{format_value(value)}</div>
      </div>
      <div :if={@metrics == %{}} class="text-sm text-base-content/40 col-span-full">
        {gettext("No activity recorded yet.")}
      </div>
    </div>
    """
  end

  defp humanize_key(key), do: key |> to_string() |> String.replace("_", " ")

  defp format_value(nil), do: "—"
  defp format_value(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 2)
  defp format_value(value), do: to_string(value)

  defp get_first_section_id([]), do: nil
  defp get_first_section_id([first | _]), do: first.id

  defp list_students(cohort_id) do
    case Learning.list_cohort_memberships(cohort_id, %{limit: 500}) do
      {:ok, {memberships, _meta}} -> Enum.map(memberships, & &1.account)
      _ -> []
    end
  end

  defp build_path(assigns_or_socket, overrides) do
    {cohort, course, current_section, current_block, current_account} =
      path_context(assigns_or_socket)

    section_id = Keyword.get(overrides, :section_id, current_section) || ""
    block_id = Keyword.get(overrides, :block_id, current_block) || ""
    account_id = Keyword.get(overrides, :account_id, current_account) || ""

    ~p"/teaching/cohorts/#{cohort.id}/engagement/#{course.id}?section_id=#{section_id}&block_id=#{block_id}&account_id=#{account_id}"
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

  # Content problems, not student problems - `:high_backtrack_rate`/
  # `:high_hesitation_rate` mean "most students struggle here", so those
  # blocks are surfaced first instead of a teacher having to open every
  # block to find which one needs rewriting. Secondary sort by `order`
  # keeps the list stable/recognizable otherwise.
  defp sorted_blocks(blocks, metrics) do
    Enum.sort_by(blocks, fn block ->
      {content_flags_for(Map.get(metrics, block.id, %{})) == [], block.order}
    end)
  end

  defp content_flags_for(block_metrics) do
    block_metrics |> Engagement.flag_concerns() |> Map.get(:content, [])
  end

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

  defp refresh_student_radar(socket) do
    since = radar_since(socket.assigns.radar_window)

    rows =
      Engagement.student_radar(socket.assigns.cohort.id, socket.assigns.course.id, since: since)

    assign(socket, :student_radar, rows)
  end

  defp radar_since("30"), do: DateTime.add(DateTime.utc_now(), -30 * 86_400, :second)
  defp radar_since("all"), do: nil
  defp radar_since(_seven_or_unknown), do: DateTime.add(DateTime.utc_now(), -7 * 86_400, :second)

  defp radar_path(assigns_or_socket, window) do
    {cohort, course, _section, _block, _account} = path_context(assigns_or_socket)
    ~p"/teaching/cohorts/#{cohort.id}/engagement/#{course.id}?view=students&window=#{window}"
  end

  # A dedicated path helper (not routed through `build_path/2`) so changing
  # the "Course Radar" charts' period never adds a `course_window` param to
  # every other patch this LiveView already builds (block/section
  # navigation, the student filter) - those keep their exact existing query
  # shape. Preserves the current section (so switching the period doesn't
  # jump back to the first section) but intentionally not the active block,
  # since the charts row this feeds only renders on the section/block-list
  # view, not the block detail view.
  defp course_charts_path(assigns_or_socket, window) do
    {cohort, course, section_id, _block, account_id} = path_context(assigns_or_socket)

    ~p"/teaching/cohorts/#{cohort.id}/engagement/#{course.id}?section_id=#{section_id || ""}&account_id=#{account_id || ""}&course_window=#{window}"
  end

  defp refresh_course_charts(socket) do
    since = radar_since(socket.assigns.course_window)

    rows =
      socket.assigns.cohort.id
      |> Engagement.section_flag_totals(socket.assigns.course.id, since: since)
      |> Enum.map(fn row ->
        %{
          label: row.section_title,
          slacking_count: row.slacking_count,
          struggling_count: row.struggling_count
        }
      end)

    cells =
      Engagement.activity_heatmap(socket.assigns.cohort.id, socket.assigns.course.id,
        since: since
      )

    funnel_rows =
      socket.assigns.cohort.id
      |> Engagement.course_funnel(socket.assigns.course.id, since: since)
      |> Enum.map(fn row ->
        %{
          label: row.section_title,
          opened: row.opened,
          interacted: row.interacted,
          completed: row.completed
        }
      end)

    trend_points =
      socket.assigns.cohort.id
      |> Engagement.active_students_trend(socket.assigns.course.id, since: since)
      |> Enum.map(fn row -> %{date: row.date, value: row.active_count} end)

    correction_rows =
      socket.assigns.cohort.id
      |> Engagement.nudge_correction_rate(socket.assigns.course.id, since: since)
      |> Enum.map(fn row ->
        %{label: humanize_key(row.reason), correction_rate: row.correction_rate}
      end)

    socket
    |> assign(:section_chart_config, ChartConfig.stacked_bar_config(rows))
    |> assign(:heatmap_config, ChartConfig.heatmap_config(cells))
    |> assign(:funnel_chart_config, ChartConfig.funnel_config(funnel_rows))
    |> assign(
      :trend_chart_config,
      ChartConfig.line_config(trend_points, dataset_label: "Active students")
    )
    |> assign(:correction_rate_chart_config, ChartConfig.correction_rate_config(correction_rows))
  end

  defp content_view_path(assigns_or_socket) do
    {cohort, course, _section, _block, _account} = path_context(assigns_or_socket)
    ~p"/teaching/cohorts/#{cohort.id}/engagement/#{course.id}"
  end

  # Deep-links a "Student radar" row straight into the existing "Course
  # radar" block detail view, pre-filtered to this student and already
  # opened on their first flagged block (slacking outranks struggling,
  # since it is the more urgent case) - a teacher should never have to
  # manually re-find what the table already told them.
  defp student_detail_path(assigns, row) do
    case first_flagged_block(row) do
      nil ->
        build_path(assigns, account_id: row.account_id, section_id: nil, block_id: nil)

      block_id ->
        case Content.get_block(block_id) do
          {:ok, block} ->
            build_path(assigns,
              account_id: row.account_id,
              section_id: block.section_id,
              block_id: block.id
            )

          _ ->
            build_path(assigns, account_id: row.account_id, section_id: nil, block_id: nil)
        end
    end
  end

  defp first_flagged_block(row) do
    Enum.find_value(row.flagged_blocks, fn fb -> fb.slacking_count > 0 && fb.block_id end) ||
      Enum.find_value(row.flagged_blocks, fn fb -> fb.struggling_count > 0 && fb.block_id end)
  end

  defp refresh_metrics(socket) do
    scope = %{cohort_id: socket.assigns.cohort.id, account_id: socket.assigns.active_account_id}

    metrics =
      cond do
        socket.assigns.active_block ->
          Engagement.get_metrics(
            Map.merge(scope, %{resource_type: :block, resource_id: socket.assigns.active_block.id})
          )

        socket.assigns.active_section ->
          Engagement.get_metrics(
            Map.merge(scope, %{
              resource_type: :section,
              resource_id: socket.assigns.active_section.id
            })
          )

        true ->
          %{}
      end

    assign(socket, :metrics, metrics)
  end
end
