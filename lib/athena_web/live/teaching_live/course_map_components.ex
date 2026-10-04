defmodule AthenaWeb.TeachingLive.CourseMapComponents do
  @moduledoc """
  The Course Map - the main view of the Course Radar
  (`AthenaWeb.TeachingLive.CohortEngagement`): the whole course as a tree,
  one row per block, coloured by how much of a problem spot it is, with the
  numbers behind it. Answers "where in the course" rather than "who".

  Two lenses, from the same `Athena.Engagement.course_map/3` data:

    * the cohort - who opened and completed each block, how long they
      spent, how they scored, and the cohort-wide issues
      (`Athena.Engagement.CourseMap`);
    * one student - their own time, score and signals on every block,
      always next to the cohort's number.

  A "problem spots" list on top names the worst blocks first.
  """
  use AthenaWeb, :html

  alias AthenaWeb.TeachingLive.EngagementExplanations, as: Explanations
  alias AthenaWeb.TeachingLive.GradebookTable

  @top_problems 5

  attr :map, :map, required: true
  attr :block_names, :map, required: true
  attr :block_path, :any, required: true, doc: "fun(block_id) -> path"
  attr :student, :map, default: nil, doc: "the student in focus, or nil for the cohort"
  attr :section_id, :string, default: nil, doc: "only this section, or nil for all"
  attr :only_problems?, :boolean, default: false

  def course_map(assigns) do
    sections =
      visible_sections(assigns.map, assigns.section_id, assigns.student, assigns.only_problems?)

    assigns =
      assigns
      |> assign(:sections, sections)
      |> assign(:top, top_problems(assigns.map, sections, assigns.student))

    ~H"""
    <div id="course-map" class="space-y-4">
      <.problem_list
        top={@top}
        map={@map}
        block_names={@block_names}
        block_path={@block_path}
        student={@student}
      />

      <div
        :if={@sections == []}
        id="course-map-empty"
        class="bg-base-100 border border-base-200 rounded-sm p-8 text-center text-base-content/60"
      >
        <.icon name="hero-check-badge" class="size-8 text-success mx-auto mb-2" />
        {if @only_problems?,
          do: gettext("No problem spots in this part of the course."),
          else: gettext("This part of the course has no blocks yet.")}
      </div>

      <section
        :for={
          %{section: section, depth: depth, block_ids: block_ids, problems: problems} <- @sections
        }
        id={"map-section-#{section.id}"}
        class="bg-base-100 border border-base-200 rounded-sm overflow-hidden"
        style={"margin-left: #{depth * 1}rem"}
      >
        <header class="flex items-center justify-between gap-3 px-4 py-2.5 bg-base-200/40 border-b border-base-200">
          <h3 class="font-black truncate">{section.title}</h3>
          <span class="text-xs text-base-content/50 shrink-0">
            {ngettext("%{count} block", "%{count} blocks", length(block_ids))}
            <span :if={problems > 0} class="text-warning font-bold">
              · {ngettext("%{count} problem spot", "%{count} problem spots", problems)}
            </span>
          </span>
        </header>
        <ul class="divide-y divide-base-200">
          <.block_row
            :for={block_id <- block_ids}
            block={@map.blocks[block_id]}
            entry={@map.entries[block_id]}
            name={Map.get(@block_names, block_id, "")}
            path={@block_path.(block_id)}
            student={@student}
          />
        </ul>
      </section>
    </div>
    """
  end

  # Sections in course order with only the rows to show; empty ones (all
  # filtered out) are dropped.
  defp visible_sections(map, section_id, student, only_problems?) do
    for %{section: section} = row <- map.sections,
        is_nil(section_id) or section.id == section_id,
        block_ids =
          Enum.filter(row.block_ids, &(not only_problems? or problem?(map.entries[&1], student))),
        block_ids != [] do
      Map.merge(row, %{
        block_ids: block_ids,
        problems: Enum.count(block_ids, &problem?(map.entries[&1], student))
      })
    end
  end

  defp problem?(entry, nil), do: entry.severity != nil
  defp problem?(entry, _student), do: entry.student.severity != nil

  defp severity(entry, nil), do: entry.severity
  defp severity(entry, _student), do: entry.student.severity

  defp top_problems(map, sections, student) do
    sections
    |> Enum.flat_map(& &1.block_ids)
    |> Enum.with_index()
    |> Enum.map(fn {block_id, position} ->
      entry = map.entries[block_id]
      count = if student, do: length(entry.student.signals), else: length(entry.issues)
      {position, block_id, severity(entry, student), count}
    end)
    |> Athena.Engagement.rank_course_map(@top_problems)
  end

  attr :top, :list, required: true
  attr :map, :map, required: true
  attr :block_names, :map, required: true
  attr :block_path, :any, required: true
  attr :student, :map, default: nil

  defp problem_list(assigns) do
    ~H"""
    <section id="problem-spots" class="bg-base-100 border border-base-200 rounded-sm p-4">
      <h2 class="flex items-center gap-2 text-sm font-black uppercase tracking-wider text-base-content/60 mb-3">
        <.icon name="hero-fire" class="size-4 text-error" />
        {if @student,
          do: gettext("Where %{name} has trouble", name: @student.name),
          else: gettext("Problem spots in the course")}
      </h2>
      <p :if={@top == []} class="text-sm text-success flex items-center gap-2">
        <.icon name="hero-check-circle" class="size-5" />
        {if @student,
          do: gettext("Nothing stands out for this student in this period."),
          else: gettext("No block stands out for this group in this period.")}
      </p>
      <ol :if={@top != []} class="space-y-1">
        <li :for={{block_id, index} <- Enum.with_index(@top, 1)}>
          <.link
            patch={@block_path.(block_id)}
            id={"problem-#{block_id}"}
            class="group flex items-start gap-3 rounded-sm px-2 py-1.5 hover:bg-base-200 transition-colors"
          >
            <span class={[
              "flex size-6 shrink-0 items-center justify-center rounded-full text-xs font-black",
              severity_badge(severity(@map.entries[block_id], @student))
            ]}>
              {index}
            </span>
            <span class="min-w-0">
              <span class="block font-bold group-hover:text-primary transition-colors truncate">
                {Map.get(@block_names, block_id, "")}
              </span>
              <span class="block text-xs text-base-content/60">
                {headline(@map.entries[block_id], @student, @block_names)}
              </span>
            </span>
          </.link>
        </li>
      </ol>
    </section>
    """
  end

  defp headline(entry, nil, _names) do
    entry.issues
    |> Enum.map(&"#{Explanations.issue_label(&1.key)}: #{Explanations.issue_note(&1)}")
    |> Enum.join(" · ")
  end

  defp headline(entry, _student, names) do
    entry.student.signals
    |> Enum.take(2)
    |> Enum.map(fn signal ->
      %{note: note} = Explanations.explain(signal, names)

      if note == "",
        do: Explanations.short_label(signal.key),
        else: "#{Explanations.short_label(signal.key)}: #{note}"
    end)
    |> Enum.join(" · ")
  end

  attr :block, :map, required: true
  attr :entry, :map, required: true
  attr :name, :string, required: true
  attr :path, :string, required: true
  attr :student, :map, default: nil

  defp block_row(assigns) do
    ~H"""
    <li id={"map-block-#{@block.id}"}>
      <.link
        patch={@path}
        class={[
          "group grid grid-cols-[auto_minmax(0,1fr)_auto] items-center gap-x-3 gap-y-1 px-4 py-2.5",
          "border-l-4 transition-colors hover:bg-base-200/60",
          severity_border(severity(@entry, @student))
        ]}
      >
        <.icon
          name={GradebookTable.type_icon(@block.type)}
          class="size-5 text-base-content/40 group-hover:text-primary transition-colors"
        />
        <div class="min-w-0">
          <div class="font-bold text-sm truncate group-hover:text-primary transition-colors">
            {@name}
          </div>
          <.row_chips entry={@entry} student={@student} />
        </div>
        <div class="flex items-center gap-4 text-xs text-base-content/70 justify-self-end">
          <%= if @student do %>
            <.student_numbers block={@block} entry={@entry} />
          <% else %>
            <.cohort_numbers block={@block} entry={@entry} />
          <% end %>
          <.icon
            name="hero-chevron-right"
            class="size-4 text-base-content/30 group-hover:text-primary group-hover:translate-x-0.5 transition-all"
          />
        </div>
      </.link>
    </li>
    """
  end

  attr :entry, :map, required: true
  attr :student, :map, default: nil

  defp row_chips(%{student: nil} = assigns) do
    ~H"""
    <div :if={@entry.issues != []} class="flex flex-wrap gap-1 mt-0.5">
      <span
        :for={issue <- @entry.issues}
        class={[
          "badge badge-sm badge-soft gap-1",
          if(issue.critical?, do: "badge-error", else: "badge-warning")
        ]}
        title={Explanations.issue_note(issue)}
      >
        {Explanations.issue_label(issue.key)}
      </span>
    </div>
    """
  end

  defp row_chips(assigns) do
    assigns = assign(assigns, :chips, Explanations.chips(assigns.entry.student.signals))

    ~H"""
    <div :if={@chips != []} class="flex flex-wrap gap-1 mt-0.5">
      <span :for={chip <- @chips} class={["badge badge-sm badge-soft", "badge-#{chip.tone}"]}>
        {chip.label}
      </span>
    </div>
    """
  end

  attr :block, :map, required: true
  attr :entry, :map, required: true

  defp cohort_numbers(assigns) do
    assigns = assign(assigns, :stats, assigns.entry.stats)

    ~H"""
    <span
      class="flex items-center gap-1.5 tabular-nums"
      title={gettext("Opened in this period / completed (whole course)")}
    >
      <.icon name="hero-eye-mini" class="size-3.5 opacity-60" />
      {@stats.opened}/{@stats.students}
      <span class="text-base-content/40">·</span>
      <.icon name="hero-check-mini" class="size-3.5 opacity-60" />
      {@stats.completed}
    </span>
    <span
      :if={@stats.avg_dwell}
      class="hidden md:flex items-center gap-1 tabular-nums"
      title={gettext("Average time on the block")}
    >
      <.icon name="hero-clock-mini" class="size-3.5 opacity-60" />
      {Explanations.duration(@stats.avg_dwell)}
    </span>
    <span
      :if={@stats.scored > 0}
      class={["flex items-center gap-1 tabular-nums font-bold", score_color(@stats)]}
      title={gettext("Average score · share who passed")}
    >
      {round(@stats.score_avg)}
      <span class="font-normal text-base-content/50">
        · {round(@stats.passed / @stats.scored * 100)}%
      </span>
    </span>
    """
  end

  defp score_color(%{scored: scored, passed: passed}) when passed / scored < 0.6, do: "text-error"
  defp score_color(_stats), do: "text-base-content"

  defp student_numbers(assigns) do
    assigns = assign(assigns, student: assigns.entry.student, stats: assigns.entry.stats)

    ~H"""
    <span :if={!@student.opened? && is_nil(@student.cell)} class="italic text-base-content/40">
      {gettext("not opened")}
    </span>
    <span
      :if={@student.avg_dwell}
      class="flex items-center gap-1 tabular-nums"
      title={gettext("Their time · the group's median")}
    >
      <.icon name="hero-clock-mini" class="size-3.5 opacity-60" />
      {Explanations.duration(@student.avg_dwell)}
      <span :if={@stats.dwell_median} class="text-base-content/40">
        / {Explanations.duration(@stats.dwell_median)}
      </span>
    </span>
    <span
      :if={@student.cell}
      class="flex items-center gap-1 tabular-nums"
      title={gettext("Their score · the group's average")}
    >
      <span class={["font-bold", cell_color(@student.cell)]}>{cell_value(@student.cell)}</span>
      <span :if={@stats.score_avg} class="text-base-content/40">/ {round(@stats.score_avg)}</span>
      <span :if={@student.cell.attempts > 1} class="text-base-content/50">
        ×{@student.cell.attempts}
      </span>
    </span>
    <.icon :if={@student.completed?} name="hero-check-circle-mini" class="size-4 text-success" />
    """
  end

  defp cell_value(%{state: :scored, score: score}), do: score
  defp cell_value(%{state: :review}), do: gettext("review")
  defp cell_value(_cell), do: "…"

  defp cell_color(%{state: :scored, score: score}) when score < 50, do: "text-error"
  defp cell_color(_cell), do: "text-base-content"

  defp severity_border(:high), do: "border-error"
  defp severity_border(:medium), do: "border-warning"
  defp severity_border(_none), do: "border-transparent"

  defp severity_badge(:high), do: "bg-error text-error-content"
  defp severity_badge(_medium), do: "bg-warning text-warning-content"
end
