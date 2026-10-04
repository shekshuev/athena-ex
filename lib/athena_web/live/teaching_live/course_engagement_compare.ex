defmodule AthenaWeb.TeachingLive.CourseEngagementCompare do
  @moduledoc """
  Cross-cohort comparison for one course: how the groups (or teams) taking
  it differ, in words a teacher can act on.

    * a few sentences first - what is clearly worse somewhere, which topic
      is hard for everyone, which group is behind in which section;
    * a table of plain-language indicators (progress, results, how they
      learn, integrity), each group next to the course average with an
      arrow when it is clearly better or worse - every cell links to that
      group's Group Radar filtered to the students behind the number;
    * a topics × groups matrix (average score or completion per section).

  Numbers come from `Athena.Engagement.cohort_summary/3`, one task per
  cohort, off the LiveView process; wording and the "course average" (all
  selected groups added together) from `AthenaWeb.TeachingLive.CohortComparison`.
  The selection, period and matrix metric live in the URL.
  """
  use AthenaWeb, :live_view

  require Logger

  alias Athena.{Content, Engagement, Learning}
  alias AthenaWeb.TeachingLive.CohortComparison, as: Comparison

  on_mount {AthenaWeb.Hooks.Permission, "engagement.read"}

  @radar_windows ~w(7 30 all)
  @max_selected 5

  # Which Group Radar level explains each indicator's number.
  @drilldown %{
    progress: :behind,
    inactive: :inactive,
    score: :not_mastering,
    first_try: :not_mastering,
    slacking: :superficial,
    struggling: :struggling,
    integrity: :integrity,
    flagged: :integrity
  }

  @impl true
  def mount(%{"course_id" => course_id}, _session, socket) do
    user = socket.assigns.current_user

    case Content.get_course(course_id) do
      {:ok, course} ->
        cohorts = Learning.list_cohorts_for_course(user, course_id)

        {:ok,
         socket
         |> assign(:course, course)
         |> assign(:cohorts, cohorts)
         |> assign(:sections, course.id |> Content.get_course_tree(:all) |> flatten())
         |> assign(:selected_cohort_ids, [])
         |> assign(:window, "7")
         |> assign(:matrix, :score)
         |> assign(:summaries, %{})
         |> assign(:loaded_key, nil)
         |> assign(:loading, false)
         |> assign(:page_title, compare_title(course))}

      {:error, _reason} ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Course not found."))
         |> push_navigate(to: ~p"/teaching/cohorts")}
    end
  end

  defp flatten(sections), do: Enum.flat_map(sections, &[&1 | flatten(&1.children)])

  defp cohorts_index_path(%{type: :competition}), do: ~p"/teaching/teams"
  defp cohorts_index_path(_course), do: ~p"/teaching/cohorts"

  defp compare_title(%{type: :competition} = course),
    do: gettext("Compare teams: %{course}", course: course.title)

  defp compare_title(course), do: gettext("Compare cohorts: %{course}", course: course.title)

  defp back_label(%{type: :competition}), do: gettext("Back to Teams")
  defp back_label(_course), do: gettext("Back to Cohorts")

  @impl true
  def handle_params(params, _url, socket) do
    all_ids = Enum.map(socket.assigns.cohorts, & &1.id)

    selected_ids =
      case params["cohort_ids"] do
        nil ->
          Enum.take(all_ids, @max_selected)

        "" ->
          []

        csv ->
          csv |> String.split(",") |> Enum.filter(&(&1 in all_ids)) |> Enum.take(@max_selected)
      end

    window = if params["window"] in @radar_windows, do: params["window"], else: "7"

    socket =
      socket
      |> assign(:selected_cohort_ids, selected_ids)
      |> assign(:window, window)
      |> assign(:matrix, if(params["matrix"] == "completion", do: :completion, else: :score))
      |> refresh_summaries()

    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_cohort", %{"cohort_id" => cohort_id}, socket) do
    selected = socket.assigns.selected_cohort_ids

    new_selected =
      if cohort_id in selected,
        do: List.delete(selected, cohort_id),
        else: Enum.take(selected ++ [cohort_id], @max_selected)

    {:noreply, push_patch(socket, to: compare_path(socket.assigns, cohort_ids: new_selected))}
  end

  def handle_event("change_window", %{"window" => window}, socket) do
    {:noreply, push_patch(socket, to: compare_path(socket.assigns, window: window))}
  end

  @impl true
  def render(assigns) do
    selected =
      Enum.filter(assigns.cohorts, &(&1.id in assigns.selected_cohort_ids))

    pairs =
      for cohort <- selected,
          summary = Map.get(assigns.summaries, cohort.id),
          summary != nil,
          do: {cohort, summary}

    merged = pairs |> Enum.map(&elem(&1, 1)) |> Comparison.merge()

    assigns =
      assigns
      |> assign(:pairs, pairs)
      |> assign(:merged, merged)
      |> assign(:insights, Comparison.insights(pairs, assigns.sections))
      |> assign(:team?, assigns.course.type == :competition)

    ~H"""
    <.page_container size="wide" class="p-4 sm:p-6 lg:p-8 space-y-5">
      <.link
        navigate={cohorts_index_path(@course)}
        class="inline-flex items-center gap-2 text-xs font-bold uppercase tracking-widest text-base-content/50 hover:text-primary transition-colors"
      >
        <.icon name="hero-arrow-left" class="size-4" />
        {back_label(@course)}
      </.link>

      <div class="flex flex-wrap items-end justify-between gap-4">
        <div>
          <h1 class="text-2xl font-black">{compare_title(@course)}</h1>
          <p class="text-sm text-base-content/60">
            {gettext("How the groups differ, and where to look first")}
          </p>
        </div>

        <form phx-change="change_window">
          <select name="window" class="select select-bordered select-sm rounded-sm">
            <option value="7" selected={@window == "7"}>{gettext("Last 7 days")}</option>
            <option value="30" selected={@window == "30"}>{gettext("Last 30 days")}</option>
            <option value="all" selected={@window == "all"}>{gettext("Whole course")}</option>
          </select>
        </form>
      </div>

      <div class="bg-base-100 border border-base-200 rounded-sm p-4">
        <h2 class="text-xs font-black uppercase tracking-widest text-base-content/50 mb-2">
          {if @team?, do: gettext("Teams"), else: gettext("Cohorts")}
          <span class="normal-case tracking-normal font-normal">
            · {gettext("up to %{count} at once", count: max_selected())}
          </span>
        </h2>
        <div class="flex flex-wrap gap-2">
          <.button
            :for={cohort <- @cohorts}
            variant={if cohort.id in @selected_cohort_ids, do: "primary", else: "ghost"}
            size="sm"
            type="button"
            phx-click="toggle_cohort"
            phx-value-cohort_id={cohort.id}
          >
            {cohort.name}
          </.button>
          <.empty_state
            :if={@cohorts == []}
            icon="hero-user-group"
            title={
              if @team?,
                do: gettext("No teams are enrolled in this course yet."),
                else: gettext("No cohorts are enrolled in this course yet.")
            }
          />
        </div>
      </div>

      <div
        :if={@loading}
        id="cohort-compare-loading"
        class="space-y-3"
        aria-busy="true"
      >
        <div :for={_ <- 1..3} class="h-24 rounded-sm bg-base-100 border border-base-200 animate-pulse">
        </div>
      </div>

      <%= if !@loading and @pairs != [] do %>
        <section id="compare-insights" class="bg-base-100 border border-base-200 rounded-sm p-4">
          <h2 class="flex items-center gap-2 text-sm font-black uppercase tracking-wider text-base-content/60 mb-2">
            <.icon name="hero-light-bulb" class="size-4 text-primary" /> {gettext("At a glance")}
          </h2>
          <p :if={@insights == []} class="text-sm text-success flex items-center gap-2">
            <.icon name="hero-check-circle" class="size-5" />
            {gettext("No group stands out - they are within a few points of each other.")}
          </p>
          <ul :if={@insights != []} class="space-y-1.5 text-sm">
            <li :for={line <- @insights} class="flex gap-2">
              <.icon name="hero-arrow-right-mini" class="size-4 mt-0.5 shrink-0 text-primary" />
              <span>{line}</span>
            </li>
          </ul>
        </section>

        <.indicator_table
          pairs={@pairs}
          merged={@merged}
          course={@course}
          window={@window}
        />

        <.topics_matrix
          pairs={@pairs}
          merged={@merged}
          sections={@sections}
          matrix={@matrix}
          path_fn={&compare_path(assigns, matrix: &1)}
        />
      <% end %>
    </.page_container>
    """
  end

  defp max_selected, do: @max_selected

  attr :pairs, :list, required: true
  attr :merged, :map, required: true
  attr :course, :map, required: true
  attr :window, :string, required: true

  defp indicator_table(assigns) do
    ~H"""
    <div class="bg-base-100 border border-base-200 rounded-sm overflow-x-auto">
      <table id="cohort-compare-table" class="table">
        <thead>
          <tr class="text-xs uppercase tracking-wider text-base-content/50">
            <th class="min-w-64"></th>
            <th :for={{cohort, summary} <- @pairs} class="text-center">
              <div class="font-black normal-case tracking-normal text-sm text-base-content">
                {cohort.name}
              </div>
              <div class="font-normal normal-case tracking-normal">
                {ngettext("%{count} student", "%{count} students", summary.students)}
              </div>
            </th>
            <th class="text-center bg-base-200/50">{gettext("Course average")}</th>
          </tr>
        </thead>
        <tbody>
          <%= for group <- Comparison.groups() do %>
            <tr>
              <td
                colspan={length(@pairs) + 2}
                class="bg-base-200/40 text-xs font-black uppercase tracking-wider text-base-content/60 py-1.5"
              >
                {Comparison.group_label(group)}
              </td>
            </tr>
            <tr
              :for={indicator <- Enum.filter(Comparison.indicators(), &(&1.group == group))}
              id={"indicator-#{indicator.key}"}
            >
              <td>
                <span class="flex items-center gap-1.5">
                  {Comparison.label(indicator.key)}
                  <span
                    class="tooltip tooltip-right"
                    data-tip={Comparison.help(indicator.key)}
                    title={Comparison.help(indicator.key)}
                  >
                    <.icon name="hero-question-mark-circle" class="size-4 text-base-content/30" />
                  </span>
                </span>
              </td>
              <td :for={{cohort, summary} <- @pairs} class="text-center">
                <.indicator_cell
                  value={Comparison.value(summary, indicator.key)}
                  average={Comparison.value(@merged, indicator.key)}
                  indicator={indicator}
                  href={radar_link(cohort, @course, @window, indicator.key)}
                  id={"cell-#{indicator.key}-#{cohort.id}"}
                />
              </td>
              <td class="text-center bg-base-200/50 font-mono font-bold text-base-content/70">
                {Comparison.format(Comparison.value(@merged, indicator.key), indicator)}
              </td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
    """
  end

  attr :value, :any, required: true
  attr :average, :any, required: true
  attr :indicator, :map, required: true
  attr :href, :string, required: true
  attr :id, :string, required: true

  defp indicator_cell(assigns) do
    assigns =
      assign(
        assigns,
        :dev,
        Comparison.deviation(assigns.value, assigns.average, assigns.indicator)
      )

    ~H"""
    <.link
      id={@id}
      navigate={@href}
      class={[
        "inline-flex items-center justify-center gap-1 rounded-sm px-2 py-1 font-mono font-bold tabular-nums transition-colors hover:ring-2 hover:ring-primary/30",
        dev_class(@dev)
      ]}
      data-deviation={"#{@dev.level}-#{if @dev.good?, do: "good", else: "bad"}"}
    >
      {Comparison.format(@value, @indicator)}
      <.icon :if={@dev.level > 0} name={dev_icon(@dev, @value, @average)} class="size-3.5" />
      <.icon :if={@dev.level > 1} name={dev_icon(@dev, @value, @average)} class="size-3.5 -ml-2" />
    </.link>
    """
  end

  defp dev_class(%{level: 0}), do: "text-base-content"
  defp dev_class(%{level: 1, good?: true}), do: "bg-success/10 text-success"
  defp dev_class(%{level: 2, good?: true}), do: "bg-success/20 text-success"
  defp dev_class(%{level: 1}), do: "bg-warning/15 text-warning-content"
  defp dev_class(%{level: 2}), do: "bg-error/15 text-error"

  defp dev_icon(_dev, value, average) when value > average, do: "hero-arrow-up-mini"
  defp dev_icon(_dev, _value, _average), do: "hero-arrow-down-mini"

  attr :pairs, :list, required: true
  attr :merged, :map, required: true
  attr :sections, :list, required: true
  attr :matrix, :atom, required: true
  attr :path_fn, :any, required: true

  defp topics_matrix(assigns) do
    assigns =
      assign(
        assigns,
        :rows,
        Enum.filter(assigns.sections, &Map.has_key?(assigns.merged.sections, &1.id))
      )

    ~H"""
    <section id="topics-matrix" class="bg-base-100 border border-base-200 rounded-sm p-4 space-y-3">
      <div class="flex flex-wrap items-center justify-between gap-3">
        <h2 class="text-sm font-black uppercase tracking-wider text-base-content/60">
          {gettext("Topics × groups")}
        </h2>
        <div class="join">
          <.link
            id="matrix-score"
            patch={@path_fn.(:score)}
            class={matrix_tab(@matrix == :score)}
          >
            {gettext("Average score")}
          </.link>
          <.link
            id="matrix-completion"
            patch={@path_fn.(:completion)}
            class={matrix_tab(@matrix == :completion)}
          >
            {gettext("Completed")}
          </.link>
        </div>
      </div>
      <div class="overflow-x-auto">
        <table class="table table-sm">
          <thead>
            <tr class="text-xs text-base-content/50">
              <th>{gettext("Section")}</th>
              <th :for={{cohort, _summary} <- @pairs} class="text-center">{cohort.name}</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={section <- @rows} id={"topic-#{section.id}"}>
              <td class="font-bold">{section.title}</td>
              <td :for={{cohort, summary} <- @pairs} class="text-center p-1">
                <% value = matrix_value(@matrix, summary, section.id) %>
                <span
                  id={"topic-#{section.id}-#{cohort.id}"}
                  class={[
                    "inline-block w-full rounded-sm py-1.5 font-mono font-bold tabular-nums",
                    heat(@matrix, value)
                  ]}
                >
                  {format_matrix(@matrix, value)}
                </span>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
      <p class="text-xs text-base-content/50">
        {if @matrix == :score,
          do: gettext("Average best score on the section's graded tasks, whole course."),
          else: gettext("Share of the section's blocks completed by the group's students.")}
      </p>
    </section>
    """
  end

  defp matrix_tab(active?),
    do: [
      "btn btn-xs join-item rounded-sm",
      if(active?, do: "btn-primary", else: "btn-ghost border-base-300")
    ]

  defp matrix_value(:score, summary, section_id),
    do: Comparison.section_score(summary, section_id)

  defp matrix_value(:completion, summary, section_id),
    do: Comparison.section_completion(summary, section_id)

  defp format_matrix(_matrix, nil), do: "–"
  defp format_matrix(:score, value), do: "#{round(value)}"
  defp format_matrix(:completion, value), do: "#{round(value)}%"

  # Same scale for both metrics (0..100): red below 50, amber below 70,
  # green from 85.
  defp heat(_matrix, nil), do: "text-base-content/30"
  defp heat(_matrix, value) when value < 50, do: "bg-error/20 text-error"
  defp heat(_matrix, value) when value < 70, do: "bg-warning/20 text-warning-content"
  defp heat(_matrix, value) when value < 85, do: "bg-success/10"
  defp heat(_matrix, _value), do: "bg-success/25 text-success"

  defp radar_link(cohort, course, window, indicator) do
    base =
      if cohort.type == :team,
        do: ~p"/teaching/teams/#{cohort.id}/engagement/#{course.id}",
        else: ~p"/teaching/cohorts/#{cohort.id}/engagement/#{course.id}"

    base <>
      "?" <>
      URI.encode_query(view: "students", window: window, level: Map.fetch!(@drilldown, indicator))
  end

  defp compare_path(assigns, overrides) do
    cohort_ids = Keyword.get(overrides, :cohort_ids, assigns.selected_cohort_ids)
    window = Keyword.get(overrides, :window, assigns.window)
    matrix = Keyword.get(overrides, :matrix, assigns.matrix)

    query =
      [cohort_ids: Enum.join(cohort_ids, ","), window: window]
      |> then(&if(matrix == :completion, do: &1 ++ [matrix: "completion"], else: &1))
      |> URI.encode_query()

    ~p"/teaching/courses/#{assigns.course.id}/engagement/compare" <> "?" <> query
  end

  # One task per cohort, in parallel, off the LiveView process; only a new
  # selection or period recomputes anything (switching the matrix doesn't).
  defp refresh_summaries(socket) do
    key = {socket.assigns.selected_cohort_ids, socket.assigns.window}

    cond do
      not connected?(socket) ->
        assign(socket, :loading, true)

      socket.assigns.loaded_key == key ->
        socket

      true ->
        since = compare_since(socket.assigns.window)
        course_id = socket.assigns.course.id

        cohorts =
          Enum.filter(socket.assigns.cohorts, &(&1.id in socket.assigns.selected_cohort_ids))

        socket
        |> assign(:loading, cohorts != [])
        |> assign(:loaded_key, key)
        |> cancel_async(:summaries)
        |> start_async(:summaries, fn -> fetch_summaries(cohorts, course_id, since) end)
    end
  end

  defp fetch_summaries(cohorts, course_id, since) do
    cohorts
    |> Task.async_stream(
      &{&1.id, Engagement.cohort_summary(&1.id, course_id, since: since)},
      timeout: :infinity
    )
    |> Map.new(fn {:ok, pair} -> pair end)
  end

  @impl true
  def handle_async(:summaries, {:ok, summaries}, socket) do
    {:noreply, socket |> assign(:summaries, summaries) |> assign(:loading, false)}
  end

  def handle_async(:summaries, {:exit, reason}, socket) do
    Logger.error("Cohort comparison failed: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(:loading, false)
     |> put_flash(:error, gettext("Could not load engagement data. Please try again."))}
  end

  defp compare_since("30"), do: Engagement.window_start(30)
  defp compare_since("all"), do: nil
  defp compare_since(_seven_or_unknown), do: Engagement.window_start(7)
end
