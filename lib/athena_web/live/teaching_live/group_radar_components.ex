defmodule AthenaWeb.TeachingLive.GroupRadarComponents do
  @moduledoc """
  The Group Radar screen of `AthenaWeb.TeachingLive.CohortEngagement`:
  who needs attention, why, and what to do about it - for a teacher who
  has never seen how the numbers are made.

    * level tiles (`level_tiles/1`) - how many students are at each level,
      doubling as a filter;
    * the table (`radar_table/1`) - one row per student with their level
      and the reasons behind it as short chips;
    * the student drawer (`student_drawer/1`) - every signal spelled out
      against what it was compared with, plus concrete advice;
    * the methodology modal (`methodology_modal/1`) - how a level is decided.

  All wording comes from `AthenaWeb.TeachingLive.EngagementExplanations`;
  all navigation is plain `patch`/`navigate` links built by the LiveView.
  """
  use AthenaWeb, :html

  alias AthenaWeb.TeachingLive.EngagementExplanations, as: Explanations

  attr :counts, :map, required: true, doc: "%{level => count}"
  attr :active, :atom, default: nil
  attr :level_path, :any, required: true, doc: "fun(level | nil) -> path"

  def level_tiles(assigns) do
    assigns = assign(assigns, :levels, Enum.map(Explanations.level_rules(), &elem(&1, 0)))

    ~H"""
    <div id="radar-level-tiles" class="grid grid-cols-2 sm:grid-cols-4 xl:grid-cols-7 gap-2">
      <.link
        :for={level <- @levels}
        id={"level-tile-#{level}"}
        patch={@level_path.(if @active == level, do: nil, else: level)}
        class={[
          "group relative flex flex-col gap-1 rounded-sm border p-3 transition-all duration-150",
          "hover:-translate-y-0.5 hover:shadow-md",
          tile_class(Explanations.level_tone(level), @active == level),
          Map.get(@counts, level, 0) == 0 && @active != level && "opacity-50"
        ]}
        aria-pressed={to_string(@active == level)}
      >
        <div class="flex items-center justify-between">
          <.icon name={Explanations.level_icon(level)} class="size-5" />
          <span class="font-display text-2xl font-black tabular-nums leading-none">
            {Map.get(@counts, level, 0)}
          </span>
        </div>
        <span class="text-xs font-bold leading-tight">{Explanations.level_label(level)}</span>
      </.link>
    </div>
    """
  end

  defp tile_class("error", active?),
    do:
      if(active?,
        do: "bg-error text-error-content border-error",
        else: "bg-error/5 text-error border-error/20"
      )

  defp tile_class("warning", active?),
    do:
      if(active?,
        do: "bg-warning text-warning-content border-warning",
        else: "bg-warning/10 text-warning-content border-warning/30"
      )

  defp tile_class("info", active?),
    do:
      if(active?,
        do: "bg-info text-info-content border-info",
        else: "bg-info/5 text-info border-info/20"
      )

  defp tile_class(_tone, active?),
    do:
      if(active?,
        do: "bg-success text-success-content border-success",
        else: "bg-success/5 text-success border-success/20"
      )

  attr :rows, :list, required: true
  attr :student_path, :any, required: true
  attr :filtered?, :boolean, default: false
  attr :clear_filter_path, :string, default: nil

  def radar_table(assigns) do
    ~H"""
    <div class="bg-base-100 border border-base-200 rounded-sm overflow-x-auto">
      <table id="group-radar-table" class="table">
        <thead>
          <tr class="text-xs uppercase tracking-wider text-base-content/50">
            <th>{gettext("Student")}</th>
            <th>{gettext("Status")}</th>
            <th class="min-w-64">{gettext("Why")}</th>
            <th>{gettext("Progress")}</th>
            <th class="text-right">{gettext("Avg score")}</th>
            <th class="w-8"></th>
          </tr>
        </thead>
        <tbody>
          <tr
            :for={row <- @rows}
            id={"student-row-#{row.account_id}"}
            class="group cursor-pointer transition-colors hover:bg-base-200/60"
            phx-click={JS.patch(@student_path.(row.account_id))}
          >
            <td>
              <.link
                patch={@student_path.(row.account_id)}
                class="font-bold group-hover:text-primary transition-colors"
              >
                {row.name}
              </.link>
              <div :if={row.login != row.name} class="text-xs text-base-content/50">{row.login}</div>
            </td>
            <td><.level_badge level={row.level} /></td>
            <td>
              <.reason_chips signals={row.signals} />
            </td>
            <td><.progress_bar value={row.progress_percent} /></td>
            <td class="text-right font-mono font-bold tabular-nums">
              {format_score(row.average_score)}
            </td>
            <td>
              <.icon
                name="hero-chevron-right"
                class="size-4 text-base-content/30 group-hover:text-primary group-hover:translate-x-0.5 transition-all"
              />
            </td>
          </tr>
          <tr :if={@rows == []}>
            <td colspan="6">
              <div class="py-8 text-center space-y-2">
                <p class="text-base-content/60">
                  {if @filtered?,
                    do: gettext("No students with this status."),
                    else: gettext("No students in this cohort yet.")}
                </p>
                <.link :if={@filtered?} patch={@clear_filter_path} class="link link-primary text-sm">
                  {gettext("Show everyone")}
                </.link>
              </div>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  attr :level, :atom, required: true
  attr :class, :any, default: nil

  def level_badge(assigns) do
    ~H"""
    <.badge tone={Explanations.level_tone(@level)} class={["gap-1 whitespace-nowrap", @class]}>
      <.icon name={Explanations.level_icon(@level)} class="size-3.5" />
      {Explanations.level_label(@level)}
    </.badge>
    """
  end

  attr :signals, :list, required: true
  attr :limit, :integer, default: 3

  defp reason_chips(assigns) do
    chips = Explanations.chips(assigns.signals)

    assigns =
      assigns
      |> assign(:shown, Enum.take(chips, assigns.limit))
      |> assign(:hidden, max(length(chips) - assigns.limit, 0))

    ~H"""
    <div class="flex flex-wrap items-center gap-1">
      <span :if={@shown == []} class="text-xs text-base-content/40">–</span>
      <span
        :for={chip <- @shown}
        class={["badge badge-sm badge-soft font-medium gap-1", "badge-#{chip.tone}"]}
      >
        {chip.label}<span :if={chip.count > 1} class="opacity-70">×{chip.count}</span>
      </span>
      <span :if={@hidden > 0} class="text-xs text-base-content/50">
        {gettext("+%{count} more", count: @hidden)}
      </span>
    </div>
    """
  end

  attr :value, :any, required: true

  defp progress_bar(assigns) do
    ~H"""
    <div class="flex items-center gap-2 min-w-28">
      <div class="flex-1 h-1.5 rounded-full bg-base-200 overflow-hidden">
        <div
          class="h-full rounded-full bg-primary transition-all duration-500"
          style={"width: #{round(@value || 0)}%"}
        >
        </div>
      </div>
      <span class="text-xs font-mono tabular-nums w-9 text-right">{round(@value || 0)}%</span>
    </div>
    """
  end

  attr :row, :map, required: true
  attr :group, :map, required: true, doc: "%{progress_median, score_median}"
  attr :block_names, :map, required: true
  attr :block_path, :any, required: true, doc: "fun(block_id) -> course map path"
  attr :close_path, :string, required: true
  attr :course_map_path, :string, required: true
  attr :gradebook_path, :string, default: nil
  attr :window_label, :string, required: true

  def student_drawer(assigns) do
    rules = Map.new(Explanations.level_rules())

    groups =
      assigns.row.signals
      |> Enum.group_by(& &1.category)
      |> Enum.sort_by(fn {category, _} ->
        Enum.find_index(Explanations.categories(), &(&1 == category)) || 99
      end)

    assigns =
      assigns
      |> assign(:rule, Map.fetch!(rules, assigns.row.level))
      |> assign(:groups, groups)
      |> assign(:advice, Explanations.recommendations(assigns.row.signals, assigns.block_names))

    ~H"""
    <div
      id="student-drawer"
      class="fixed inset-0 z-50"
      phx-window-keydown={JS.patch(@close_path)}
      phx-key="escape"
    >
      <.link
        patch={@close_path}
        class="radar-drawer-overlay absolute inset-0 bg-base-content/20 backdrop-blur-[1px]"
        aria-label={gettext("Close")}
      >
      </.link>
      <aside
        class="radar-drawer-panel absolute inset-y-0 right-0 w-full max-w-xl bg-base-100 border-l border-base-300 shadow-2xl flex flex-col"
        role="dialog"
        aria-modal="true"
        aria-labelledby="student-drawer-title"
      >
        <header class="p-6 border-b border-base-200 space-y-3">
          <div class="flex items-start justify-between gap-4">
            <div class="min-w-0">
              <h2 id="student-drawer-title" class="text-xl font-display font-black truncate">
                {@row.name}
              </h2>
              <p :if={@row.login != @row.name} class="text-sm text-base-content/50">{@row.login}</p>
            </div>
            <.link
              patch={@close_path}
              class="btn btn-ghost btn-square btn-sm"
              aria-label={gettext("Close")}
            >
              <.icon name="hero-x-mark" class="size-5" />
            </.link>
          </div>
          <div class="flex flex-wrap items-center gap-2">
            <.level_badge level={@row.level} class="badge-md" />
            <span class="text-xs text-base-content/50">{@window_label}</span>
          </div>
          <p class="text-sm text-base-content/70">{@rule}</p>
          <ul :if={@row[:pattern]} id="student-patterns" class="space-y-0.5 text-xs">
            <li
              :for={kind <- [:slacking, :struggling]}
              :if={@row.pattern[kind].blocks > 0}
              class={[
                "flex items-center gap-1.5",
                if(@row.pattern[kind].fires?, do: "text-info font-bold", else: "text-base-content/50")
              ]}
            >
              <.icon
                name={if kind == :slacking, do: "hero-forward-mini", else: "hero-lifebuoy-mini"}
                class="size-3.5"
              />
              {Explanations.pattern_line(kind, @row.pattern[kind])}
            </li>
          </ul>
        </header>

        <div class="flex-1 overflow-y-auto p-6 space-y-6">
          <div class="grid grid-cols-3 gap-2">
            <.drawer_stat
              label={gettext("Progress")}
              value={"#{round(@row.progress_percent)}%"}
              compare={
                @group.progress_median && gettext("group: %{v}%", v: round(@group.progress_median))
              }
            />
            <.drawer_stat
              label={gettext("Avg score")}
              value={format_score(@row.average_score)}
              compare={@group.score_median && gettext("group: %{v}", v: round(@group.score_median))}
            />
            <.drawer_stat label={gettext("Signals")} value={length(@row.signals)} />
          </div>

          <section
            :if={@advice != []}
            id="student-advice"
            class="rounded-sm border border-primary/20 bg-primary/5 p-4"
          >
            <h3 class="flex items-center gap-2 text-sm font-black uppercase tracking-wider text-primary mb-2">
              <.icon name="hero-light-bulb" class="size-4" /> {gettext("What you can do")}
            </h3>
            <ul class="space-y-1.5 text-sm">
              <li :for={line <- @advice} class="flex gap-2">
                <.icon name="hero-arrow-right-mini" class="size-4 mt-0.5 shrink-0 text-primary" />
                <span>{line}</span>
              </li>
            </ul>
          </section>

          <section id="student-signals">
            <h3 class="text-sm font-black uppercase tracking-wider text-base-content/50 mb-3">
              {gettext("What counted")}
            </h3>
            <div
              :if={@groups == []}
              class="flex items-center gap-2 rounded-sm bg-success/5 border border-success/20 p-4 text-sm text-success"
            >
              <.icon name="hero-check-circle" class="size-5" />
              {gettext("Nothing worth worrying about in this period.")}
            </div>
            <div :for={{category, signals} <- @groups} class="mb-4 last:mb-0">
              <div class={[
                "text-xs font-bold uppercase tracking-wider mb-1.5",
                category_text(Explanations.category_tone(category))
              ]}>
                {Explanations.category_label(category)}
              </div>
              <ul class="divide-y divide-base-200 border border-base-200 rounded-sm">
                <.signal_item
                  :for={signal <- signals}
                  signal={signal}
                  block_names={@block_names}
                  block_path={@block_path}
                />
              </ul>
            </div>
          </section>
        </div>

        <footer class="p-4 border-t border-base-200 flex flex-wrap gap-2">
          <.button id="drawer-course-map" variant="primary" size="sm" patch={@course_map_path}>
            <.icon name="hero-map" class="size-4" /> {gettext("Open in course radar")}
          </.button>
          <.button
            :if={@gradebook_path}
            id="drawer-gradebook"
            variant="ghost"
            size="sm"
            navigate={@gradebook_path}
          >
            <.icon name="hero-table-cells" class="size-4" /> {gettext("Scores in gradebook")}
          </.button>
        </footer>
      </aside>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :compare, :string, default: nil

  defp drawer_stat(assigns) do
    ~H"""
    <div class="rounded-sm bg-base-200/50 p-3">
      <div class="text-[10px] font-black uppercase tracking-widest text-base-content/50">
        {@label}
      </div>
      <div class="font-display text-xl font-black tabular-nums">{@value}</div>
      <div :if={@compare} class="text-xs text-base-content/50">{@compare}</div>
    </div>
    """
  end

  attr :signal, :map, required: true
  attr :block_names, :map, required: true
  attr :block_path, :any, required: true

  defp signal_item(assigns) do
    assigns =
      assign(assigns, :explained, Explanations.explain(assigns.signal, assigns.block_names))

    ~H"""
    <li class="p-3 space-y-1">
      <div class="flex items-start justify-between gap-3">
        <span class="font-bold text-sm">{@explained.title}</span>
        <.link
          :if={@signal[:block_id]}
          patch={@block_path.(@signal.block_id)}
          class="shrink-0 text-xs link link-primary"
        >
          {gettext("Open")}
        </.link>
      </div>
      <p :if={@explained.note != ""} class="text-xs text-base-content/60">{@explained.note}</p>
      <ul :if={@explained.lines != []} class="mt-1 space-y-0.5">
        <li
          :for={{line, review} <- Enum.zip(@explained.lines, @signal[:theory] || [])}
          class="flex items-start gap-1.5 text-xs"
        >
          <.icon
            name={theory_icon(review.status)}
            class={["size-3.5 mt-0.5 shrink-0", theory_color(review.status)]}
          />
          <span>{line}</span>
        </li>
      </ul>
    </li>
    """
  end

  defp theory_icon(:skipped), do: "hero-eye-slash-mini"
  defp theory_icon(:superficial), do: "hero-forward-mini"
  defp theory_icon(_ok), do: "hero-check-mini"

  defp theory_color(:ok), do: "text-success"
  defp theory_color(_weak), do: "text-warning"

  defp category_text("error"), do: "text-error"
  defp category_text("warning"), do: "text-warning"
  defp category_text(_tone), do: "text-info"

  attr :show, :boolean, required: true

  def methodology_modal(assigns) do
    assigns = assign(assigns, :rules, Explanations.level_rules())

    ~H"""
    <.modal
      id="radar-methodology"
      show={@show}
      title={gettext("How a student's status is decided")}
      on_cancel={JS.push("close_methodology")}
      box_class="max-w-2xl"
    >
      <div class="space-y-5 text-sm">
        <p class="text-base-content/70 mt-2">
          {gettext(
            "Every student is checked against the rules below from top to bottom; the first one that matches sets the status. Nothing is weighted or hidden - the student's card lists exactly what matched."
          )}
        </p>
        <ol class="space-y-2">
          <li :for={{level, rule} <- @rules} class="flex items-start gap-3">
            <.level_badge level={level} class="shrink-0 mt-0.5" />
            <span>{rule}</span>
          </li>
        </ol>
        <div class="rounded-sm bg-base-200/60 p-4 space-y-2">
          <h4 class="font-bold">{gettext("How we compare")}</h4>
          <p class="text-base-content/70">
            {gettext(
              "Time on a block is compared with the time the teacher planned for it, or - if none was set - with how long this group usually spends there (the median). Group comparisons are only made when at least 5 students have data; with fewer, only fixed limits apply."
            )}
          </p>
          <p class="text-base-content/70">
            {gettext(
              "Behaviour and scores count only for the selected period; progress counts for the whole course. For a low score we also show how the student went through the theory right before the task."
            )}
          </p>
        </div>
        <div class="rounded-sm border border-warning/30 bg-warning/5 p-4 space-y-1">
          <h4 class="font-bold">{gettext("What the system can't see")}</h4>
          <ul class="list-disc pl-5 text-base-content/70 space-y-1">
            <li>
              {gettext("Studying outside the platform: a textbook, a lecture, a friend's notes.")}
            </li>
            <li>
              {gettext("Why a student was away - illness or a busy week look the same as giving up.")}
            </li>
            <li>
              {gettext(
                "Time with the page open but nobody at the screen is subtracted, but not perfectly."
              )}
            </li>
          </ul>
          <p class="text-base-content/70 pt-1">
            {gettext("Treat a status as a reason to look closer, not as a verdict.")}
          </p>
        </div>
      </div>
      <div class="modal-action">
        <button type="button" class="btn btn-primary btn-sm" phx-click="close_methodology">
          {gettext("Got it")}
        </button>
      </div>
    </.modal>
    """
  end

  defp format_score(nil), do: "–"
  defp format_score(score), do: score |> round() |> Integer.to_string()
end
