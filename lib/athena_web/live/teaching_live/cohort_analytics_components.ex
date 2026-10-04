defmodule AthenaWeb.TeachingLive.CohortAnalyticsComponents do
  @moduledoc """
  The tab strip shared by a cohort's per-course analytics screens - the
  engagement radars (`AthenaWeb.TeachingLive.CohortEngagement`) and the
  gradebook (`AthenaWeb.TeachingLive.CohortGradebook`) - so a teacher can
  hop between "who needs attention", "where in the course" and "what
  scores" without going back to the cohort page. Each tab only shows up
  for a teacher holding the permission its screen requires.
  """
  use AthenaWeb, :html

  alias Athena.{Content, Identity}
  alias AthenaWeb.TeachingLive.GradebookTable

  attr :cohort, :map, required: true
  attr :course, :map, required: true
  attr :current_user, :map, required: true
  attr :active, :atom, required: true, values: [:students, :content, :gradebook]

  attr :students_path, :string,
    default: nil,
    doc: "overrides the Group Radar link (e.g. to keep the chosen period)"

  def analytics_tabs(assigns) do
    assigns =
      assigns
      |> assign(:engagement?, Identity.can?(assigns.current_user, "engagement.read"))
      |> assign(:grading?, Identity.can?(assigns.current_user, "grading.read"))
      |> assign_new(:students_path, fn -> nil end)

    ~H"""
    <nav class="join" aria-label={gettext("Course analytics")}>
      <.tab
        :if={@engagement?}
        id="group-radar-tab"
        to={@students_path || students_path(@cohort, @course)}
        same_view?={@active != :gradebook}
        active?={@active == :students}
        icon="hero-user-group"
      >
        {gettext("Group Radar")}
      </.tab>
      <.tab
        :if={@engagement?}
        id="course-radar-tab"
        to={content_path(@cohort, @course)}
        same_view?={@active != :gradebook}
        active?={@active == :content}
        icon="hero-map"
      >
        {gettext("Course Radar")}
      </.tab>
      <.tab
        :if={@grading?}
        id="gradebook-tab"
        to={gradebook_path(@cohort, @course)}
        same_view?={@active == :gradebook}
        active?={@active == :gradebook}
        icon="hero-table-cells"
      >
        {gettext("Gradebook")}
      </.tab>
    </nav>
    """
  end

  attr :id, :string, required: true
  attr :to, :string, required: true
  attr :same_view?, :boolean, required: true, doc: "patch within the LiveView, else navigate"
  attr :active?, :boolean, required: true
  attr :icon, :string, required: true
  slot :inner_block, required: true

  defp tab(%{same_view?: true} = assigns) do
    ~H"""
    <.link id={@id} patch={@to} class={tab_class(@active?)}>
      <.icon name={@icon} class="size-4" /> {render_slot(@inner_block)}
    </.link>
    """
  end

  defp tab(assigns) do
    ~H"""
    <.link id={@id} navigate={@to} class={tab_class(@active?)}>
      <.icon name={@icon} class="size-4" /> {render_slot(@inner_block)}
    </.link>
    """
  end

  defp tab_class(active?) do
    [
      "btn btn-sm join-item rounded-sm gap-1.5 transition-colors",
      if(active?, do: "btn-primary", else: "btn-ghost bg-base-100 border-base-300")
    ]
  end

  @doc "Gradebook path for a cohort/course, on the academic or team side."
  def gradebook_path(%{type: :team, id: id}, course),
    do: ~p"/teaching/teams/#{id}/gradebook/#{course.id}"

  def gradebook_path(%{id: id}, course), do: ~p"/teaching/cohorts/#{id}/gradebook/#{course.id}"

  defp students_path(%{type: :team, id: id}, course),
    do: ~p"/teaching/teams/#{id}/engagement/#{course.id}?view=students"

  defp students_path(%{id: id}, course),
    do: ~p"/teaching/cohorts/#{id}/engagement/#{course.id}?view=students"

  defp content_path(%{type: :team, id: id}, course),
    do: ~p"/teaching/teams/#{id}/engagement/#{course.id}"

  defp content_path(%{id: id}, course), do: ~p"/teaching/cohorts/#{id}/engagement/#{course.id}"

  @doc """
  Readable names for every block of a course tree (`"Loops · 2. Exam"`),
  plus which section each block lives in: `{%{block_id => name},
  %{block_id => section_id}}`. Used by every screen that has to name a
  block in plain words.
  """
  def block_index(tree) do
    sections = flatten_tree(tree)

    blocks_by_section =
      sections
      |> Enum.map(& &1.id)
      |> Content.list_blocks_by_section_ids()
      |> Enum.group_by(& &1.section_id)

    for section <- sections,
        {block, number} <-
          blocks_by_section
          |> Map.get(section.id, [])
          |> Enum.sort_by(& &1.order)
          |> Enum.with_index(1),
        reduce: {%{}, %{}} do
      {names, sections_by_block} ->
        name = "#{section.title} · #{number}. #{GradebookTable.type_label(block.type)}"
        {Map.put(names, block.id, name), Map.put(sections_by_block, block.id, section.id)}
    end
  end

  defp flatten_tree(sections),
    do: Enum.flat_map(sections, &[&1 | flatten_tree(&1.children)])
end
