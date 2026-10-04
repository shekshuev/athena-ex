defmodule AthenaWeb.TeachingLive.GradebookLayerComponents do
  @moduledoc """
  The gradebook's "scores + engagement" layer
  (`AthenaWeb.TeachingLive.CohortGradebook`, `?layer=engagement`): what is
  drawn on top of plain scores once `Athena.Engagement.gradebook_engagement/3`
  has loaded.

    * markers in a cell's corners - the theory in front of the task was
      skipped or skimmed (amber dot), the cheating monitor flagged the
      attempt (red/amber diamond);
    * optional theory columns between the tasks, one icon per student;
    * the cell inspector - a side panel reading one cell next to how the
      theory before it went, ending in a one-line verdict.
  """
  use AthenaWeb, :html

  alias AthenaWeb.TeachingLive.EngagementExplanations, as: Explanations
  alias AthenaWeb.TeachingLive.GradebookTable

  # Layout helpers (used by the gradebook table)

  @doc """
  A column group's items in course order: `{:task, column}` for graded
  blocks and, when theory columns are on, `{:theory, block}` for the
  section's content blocks in between.
  """
  @spec group_items(map(), map() | nil, boolean()) :: [{:task | :theory, map()}]
  def group_items(group, layer, show_theory?) do
    tasks = Enum.map(group.columns, &{:task, &1})

    if show_theory? and layer do
      theory = layer.content_blocks |> Map.get(group.section.id, []) |> Enum.map(&{:theory, &1})
      Enum.sort_by(tasks ++ theory, fn {kind, item} -> {order_of(kind, item), kind == :task} end)
    else
      tasks
    end
  end

  defp order_of(:task, column), do: column.block.order
  defp order_of(:theory, block), do: block.order

  @doc "The student's reviews of the theory in front of a task."
  @spec task_reviews(map(), binary(), binary()) :: [map()]
  def task_reviews(layer, row_id, block_id) do
    layer.theory_by_task
    |> Map.get(block_id, [])
    |> Enum.map(&Map.get(layer.reviews, {row_id, &1}, %{block_id: &1, status: :skipped}))
  end

  # Mode switch

  attr :filters, :map, required: true
  attr :loading?, :boolean, required: true
  attr :available?, :boolean, required: true

  def mode_switch(assigns) do
    ~H"""
    <div
      :if={@available?}
      id="gradebook-mode"
      class="flex flex-wrap items-center gap-3 rounded-sm border border-base-200 bg-base-100 px-3 py-2"
    >
      <div class="join" role="radiogroup" aria-label={gettext("Gradebook mode")}>
        <button
          id="mode-scores"
          type="button"
          phx-click="set_layer"
          phx-value-layer="scores"
          class={mode_class(@filters.layer == :scores)}
          aria-pressed={to_string(@filters.layer == :scores)}
        >
          <.icon name="hero-hashtag" class="size-4" /> {gettext("Scores")}
        </button>
        <button
          id="mode-engagement"
          type="button"
          phx-click="set_layer"
          phx-value-layer="engagement"
          class={mode_class(@filters.layer == :engagement)}
          aria-pressed={to_string(@filters.layer == :engagement)}
        >
          <.icon name="hero-eye" class="size-4" /> {gettext("Scores + engagement")}
        </button>
      </div>

      <span :if={@filters.layer == :scores} class="text-xs text-base-content/60">
        {gettext("Add how students went through the theory in front of each task.")}
      </span>

      <%= if @filters.layer == :engagement do %>
        <span
          :if={@loading?}
          id="layer-loading"
          class="flex items-center gap-1.5 text-xs text-base-content/60"
        >
          <.spinner class="size-3.5" /> {gettext("Loading engagement…")}
        </span>
        <label :if={!@loading?} class="flex items-center gap-2 text-sm cursor-pointer select-none">
          <input
            id="toggle-theory"
            type="checkbox"
            class="toggle toggle-sm toggle-primary"
            checked={@filters.theory}
            phx-click="toggle_theory"
          />
          {gettext("Show theory columns")}
        </label>
        <span :if={!@loading?} class="text-xs text-base-content/60">
          {gettext("Click a cell to see why.")}
        </span>
      <% end %>
    </div>
    """
  end

  defp mode_class(active?) do
    [
      "join-item btn btn-sm rounded-sm gap-1.5",
      if(active?, do: "btn-primary", else: "btn-ghost border-base-300")
    ]
  end

  # Theory columns

  attr :block, :map, required: true
  attr :name, :string, required: true

  def theory_header(assigns) do
    ~H"""
    <th
      id={"theory-col-#{@block.id}"}
      class="sticky top-8 z-20 bg-base-200/70 backdrop-blur border-b border-base-200 px-0.5 py-1.5 font-normal w-8"
      title={@name}
    >
      <.icon
        name={GradebookTable.type_icon(@block.type)}
        class="size-3.5 text-base-content/40 mx-auto"
      />
    </th>
    """
  end

  attr :review, :map, default: nil
  attr :row_id, :string, required: true
  attr :block_id, :string, required: true
  attr :name, :string, required: true

  def theory_cell(assigns) do
    assigns = assign(assigns, :status, (assigns.review && assigns.review.status) || :skipped)

    ~H"""
    <td
      id={"theory-#{@row_id}-#{@block_id}"}
      class="border-b border-base-200 bg-base-200/30 text-center w-8"
      title={"#{@name}: #{Explanations.theory_status_label(@review || %{status: :skipped})}"}
    >
      <.icon name={theory_icon(@status)} class={["size-4", theory_color(@status)]} />
    </td>
    """
  end

  attr :layer, :map, required: true
  attr :block_id, :string, required: true
  attr :row_ids, :list, required: true

  def theory_footer(assigns) do
    studied =
      Enum.count(assigns.row_ids, fn row_id ->
        match?(%{status: :ok}, Map.get(assigns.layer.reviews, {row_id, assigns.block_id}))
      end)

    assigns =
      assign(
        assigns,
        :share,
        if(assigns.row_ids == [], do: 0, else: round(studied / length(assigns.row_ids) * 100))
      )

    ~H"""
    <td
      class="sticky bottom-0 z-20 bg-base-200 border-t border-base-300 text-center text-[10px] text-base-content/50 tabular-nums"
      title={gettext("Share of students who studied it normally")}
    >
      {@share}%
    </td>
    """
  end

  def theory_icon(:ok), do: "hero-check-mini"
  def theory_icon(:superficial), do: "hero-forward-mini"
  def theory_icon(_skipped), do: "hero-minus-mini"

  def theory_color(:ok), do: "text-success"
  def theory_color(:superficial), do: "text-warning"
  def theory_color(_skipped), do: "text-base-content/30"

  # Cell markers

  attr :cell, :map, default: nil
  attr :reviews, :list, required: true

  def cell_markers(assigns) do
    assigns =
      assign(
        assigns,
        :weak?,
        Enum.any?(assigns.reviews, &(&1.status in [:skipped, :superficial]))
      )

    ~H"""
    <span
      :if={@cell && @weak?}
      class="absolute top-0.5 right-0.5 size-1.5 rounded-full bg-warning ring-1 ring-base-100"
      data-marker="theory"
    >
    </span>
    <span
      :if={@cell && @cell[:integrity]}
      class={[
        "absolute top-0.5 left-0.5 size-1.5 rotate-45 ring-1 ring-base-100",
        if(@cell.integrity == :yellow, do: "bg-warning", else: "bg-error")
      ]}
      data-marker="integrity"
    >
    </span>
    """
  end

  # Inspector

  attr :row, :map, required: true
  attr :column, :map, required: true
  attr :cell, :map, default: nil
  attr :reviews, :list, required: true
  attr :summary, :map, required: true
  attr :threshold, :integer, required: true
  attr :block_names, :map, required: true
  attr :submission_path, :string, default: nil
  attr :radar_path, :string, default: nil
  attr :block_path, :any, default: nil

  def cell_inspector(assigns) do
    assigns =
      assign(
        assigns,
        :verdict,
        Explanations.cell_verdict(assigns.cell, assigns.reviews, assigns.threshold)
      )

    ~H"""
    <div
      id="cell-inspector"
      class="fixed inset-0 z-50"
      phx-window-keydown="close_inspect"
      phx-key="escape"
    >
      <button
        type="button"
        phx-click="close_inspect"
        class="radar-drawer-overlay absolute inset-0 bg-base-content/20 cursor-default"
        aria-label={gettext("Close")}
      >
      </button>
      <aside
        class="radar-drawer-panel absolute inset-y-0 right-0 w-full max-w-md bg-base-100 border-l border-base-300 shadow-2xl flex flex-col"
        role="dialog"
        aria-modal="true"
        aria-labelledby="cell-inspector-title"
      >
        <header class="p-5 border-b border-base-200 flex items-start justify-between gap-3">
          <div class="min-w-0">
            <h2 id="cell-inspector-title" class="font-display text-lg font-black truncate">
              {@row.name}
            </h2>
            <p class="text-sm text-base-content/60 flex items-center gap-1.5">
              <.icon name={GradebookTable.type_icon(@column.block.type)} class="size-4" />
              {GradebookTable.column_title(@column)}
            </p>
          </div>
          <button
            type="button"
            phx-click="close_inspect"
            class="btn btn-ghost btn-square btn-sm"
            aria-label={gettext("Close")}
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </header>

        <div class="flex-1 overflow-y-auto p-5 space-y-5">
          <div class="grid grid-cols-3 gap-2">
            <div class="rounded-sm bg-base-200/50 p-3">
              <div class="text-[10px] font-black uppercase tracking-widest text-base-content/50">
                {gettext("Score")}
              </div>
              <div class="font-display text-2xl font-black tabular-nums">{cell_score(@cell)}</div>
            </div>
            <div class="rounded-sm bg-base-200/50 p-3">
              <div class="text-[10px] font-black uppercase tracking-widest text-base-content/50">
                {gettext("Attempts")}
              </div>
              <div class="font-display text-2xl font-black tabular-nums">
                {(@cell && @cell.attempts) || 0}
              </div>
            </div>
            <div class="rounded-sm bg-base-200/50 p-3">
              <div class="text-[10px] font-black uppercase tracking-widest text-base-content/50">
                {gettext("Group avg")}
              </div>
              <div class="font-display text-2xl font-black tabular-nums">
                {if @summary.average, do: round(@summary.average), else: "–"}
              </div>
            </div>
          </div>

          <div
            :if={@cell && @cell[:integrity]}
            id="inspector-integrity"
            class="flex items-start gap-2 rounded-sm border border-error/30 bg-error/5 p-3 text-sm"
          >
            <.icon name="hero-shield-exclamation" class="size-5 text-error shrink-0" />
            <span>{integrity_label(@cell.integrity)}</span>
          </div>

          <section id="inspector-theory">
            <h3 class="text-xs font-black uppercase tracking-wider text-base-content/50 mb-2">
              {gettext("Theory in front of this task")}
            </h3>
            <p :if={@reviews == []} class="text-sm text-base-content/50">
              {gettext("This task has no theory right before it.")}
            </p>
            <ul
              :if={@reviews != []}
              class="divide-y divide-base-200 border border-base-200 rounded-sm"
            >
              <li :for={review <- @reviews} class="flex items-center gap-2 p-2.5 text-sm">
                <.icon
                  name={theory_icon(review.status)}
                  class={["size-4 shrink-0", theory_color(review.status)]}
                />
                <span class="flex-1 min-w-0 truncate">
                  {Map.get(@block_names, review.block_id, gettext("a block"))}
                </span>
                <span class={["text-xs shrink-0", theory_color(review.status)]}>
                  {Explanations.theory_status_label(review)}
                </span>
                <.link
                  :if={@block_path}
                  navigate={@block_path.(review.block_id)}
                  class="text-xs link link-primary shrink-0"
                >
                  {gettext("Open")}
                </.link>
              </li>
            </ul>
          </section>

          <div
            id="inspector-verdict"
            class="flex items-start gap-2 rounded-sm border border-primary/20 bg-primary/5 p-3 text-sm"
          >
            <.icon name="hero-light-bulb" class="size-5 text-primary shrink-0" />
            <span>{@verdict}</span>
          </div>
        </div>

        <footer class="p-4 border-t border-base-200 flex flex-wrap gap-2">
          <.button
            :if={@submission_path}
            id="inspector-open-answer"
            variant="primary"
            size="sm"
            navigate={@submission_path}
          >
            <.icon name="hero-document-text" class="size-4" /> {gettext("Open the answer")}
          </.button>
          <.button
            :if={@radar_path}
            id="inspector-radar"
            variant="ghost"
            size="sm"
            navigate={@radar_path}
          >
            <.icon name="hero-user-group" class="size-4" /> {gettext("Student card in group radar")}
          </.button>
        </footer>
      </aside>
    </div>
    """
  end

  defp cell_score(nil), do: "–"
  defp cell_score(%{state: :scored, score: score}), do: score
  defp cell_score(%{state: :review}), do: gettext("review")
  defp cell_score(_cell), do: "…"

  defp integrity_label(:confirmed),
    do: gettext("The teacher confirmed a violation on this attempt.")

  defp integrity_label(:red), do: gettext("The cheating monitor rated this attempt high risk.")

  defp integrity_label(:yellow),
    do: gettext("The cheating monitor noticed some violations on this attempt.")

  # Legend

  attr :filters, :map, required: true

  def layer_legend(assigns) do
    ~H"""
    <div
      :if={@filters.layer == :engagement}
      id="layer-legend"
      class="flex flex-wrap items-center gap-x-5 gap-y-2 text-xs text-base-content/60"
    >
      <span class="flex items-center gap-1.5">
        <span class="inline-block size-2 rounded-full bg-warning"></span>
        {gettext("Theory before the task skipped or skimmed")}
      </span>
      <span class="flex items-center gap-1.5">
        <span class="inline-block size-2 rotate-45 bg-error"></span>
        {gettext("Flagged by the cheating monitor")}
      </span>
      <span :if={@filters.theory} class="flex items-center gap-1.5">
        <.icon name="hero-check-mini" class="size-4 text-success" /> {gettext("studied normally")}
        <.icon name="hero-forward-mini" class="size-4 text-warning ml-2" /> {gettext("skimmed")}
        <.icon name="hero-minus-mini" class="size-4 text-base-content/30 ml-2" /> {gettext(
          "never opened"
        )}
      </span>
    </div>
    """
  end
end
