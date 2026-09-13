defmodule AthenaWeb.TeachingLive.CourseEngagementCompare do
  @moduledoc """
  Cross-cohort comparison for one course - the "Cohort Comparison" macro
  chart the single-cohort `CohortEngagement` dashboard cannot express, since
  comparing cohorts is not something a single-cohort URL can represent.

  Lists the cohorts enrolled in the course (`Athena.Learning.
  list_cohorts_for_course/2`), lets the teacher pick which ones to overlay
  (capped at `@max_selected` so the radar doesn't turn into visual noise),
  and plots one polygon per selected cohort from `Athena.Engagement.
  cohort_flag_profile/3` - the same flag-rate grid the "Student Radar" and
  "Course Radar" screens already build, just tallied per cohort instead of
  per student or per section.
  """
  use AthenaWeb, :live_view

  alias Athena.{Content, Engagement, Learning}
  alias AthenaWeb.TeachingLive.ChartConfig

  on_mount {AthenaWeb.Hooks.Permission, "engagement.read"}

  @radar_windows ~w(7 30 all)
  @max_selected 5

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
         |> assign(:selected_cohort_ids, [])
         |> assign(:window, "7")
         |> assign(:chart_config, ChartConfig.radar_config(Engagement.radar_axes(), []))
         |> assign(:page_title, gettext("Compare cohorts: %{course}", course: course.title))}

      {:error, _reason} ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Course not found."))
         |> push_navigate(to: ~p"/teaching/cohorts")}
    end
  end

  @impl true
  def handle_params(params, _url, socket) do
    all_ids = Enum.map(socket.assigns.cohorts, & &1.id)

    selected_ids =
      case params["cohort_ids"] do
        nil -> Enum.take(all_ids, @max_selected)
        "" -> []
        csv -> csv |> String.split(",") |> Enum.filter(&(&1 in all_ids))
      end

    window = if params["window"] in @radar_windows, do: params["window"], else: "7"

    socket =
      socket
      |> assign(:selected_cohort_ids, selected_ids)
      |> assign(:window, window)
      |> refresh_profiles()

    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_cohort", %{"cohort_id" => cohort_id}, socket) do
    selected = socket.assigns.selected_cohort_ids

    new_selected =
      if cohort_id in selected,
        do: List.delete(selected, cohort_id),
        else: selected ++ [cohort_id]

    {:noreply, push_patch(socket, to: compare_path(socket, new_selected, socket.assigns.window))}
  end

  def handle_event("change_window", %{"window" => window}, socket) do
    {:noreply,
     push_patch(socket, to: compare_path(socket, socket.assigns.selected_cohort_ids, window))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.page_container size="narrow" class="p-4 sm:p-6 lg:p-8">
      <.link
        navigate={~p"/teaching/cohorts"}
        class="inline-flex items-center gap-2 text-xs font-bold uppercase tracking-widest text-base-content/50 hover:text-primary transition-colors mb-4"
      >
        <.icon name="hero-arrow-left" class="size-4" />
        {gettext("Back to Cohorts")}
      </.link>

      <div class="mb-6 flex items-center justify-between gap-4">
        <h1 class="text-2xl font-black truncate">
          {gettext("Compare cohorts: %{course}", course: @course.title)}
        </h1>

        <form phx-change="change_window">
          <select name="window" class="select select-bordered select-sm rounded-sm">
            <option value="7" selected={@window == "7"}>{gettext("Last 7 days")}</option>
            <option value="30" selected={@window == "30"}>{gettext("Last 30 days")}</option>
            <option value="all" selected={@window == "all"}>{gettext("Whole course")}</option>
          </select>
        </form>
      </div>

      <div class="bg-base-100 border border-base-200 rounded-sm p-4 mb-6">
        <h2 class="text-xs font-black uppercase tracking-widest text-base-content/50 mb-2">
          {gettext("Cohorts")}
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
            title={gettext("No cohorts are enrolled in this course yet.")}
          />
        </div>
      </div>

      <div class="bg-base-100 border border-base-200 rounded-sm p-4">
        <canvas
          id="cohort-compare-radar"
          phx-hook="EngagementChart"
          data-config={Jason.encode!(@chart_config)}
          class="max-h-96"
        >
        </canvas>
      </div>
    </.page_container>
    """
  end

  defp compare_path(socket, cohort_ids, window) do
    ~p"/teaching/courses/#{socket.assigns.course.id}/engagement/compare?cohort_ids=#{Enum.join(cohort_ids, ",")}&window=#{window}"
  end

  defp refresh_profiles(socket) do
    since = compare_since(socket.assigns.window)

    series =
      socket.assigns.cohorts
      |> Enum.filter(&(&1.id in socket.assigns.selected_cohort_ids))
      |> Enum.map(fn cohort ->
        %{
          label: cohort.name,
          values:
            Engagement.cohort_flag_profile(cohort.id, socket.assigns.course.id, since: since)
        }
      end)

    assign(socket, :chart_config, ChartConfig.radar_config(Engagement.radar_axes(), series))
  end

  defp compare_since("30"), do: DateTime.add(DateTime.utc_now(), -30 * 86_400, :second)
  defp compare_since("all"), do: nil

  defp compare_since(_seven_or_unknown),
    do: DateTime.add(DateTime.utc_now(), -7 * 86_400, :second)
end
