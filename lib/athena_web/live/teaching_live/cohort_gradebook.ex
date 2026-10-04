defmodule AthenaWeb.TeachingLive.CohortGradebook do
  @moduledoc """
  The gradebook for one cohort on one course: students down the side,
  gradable blocks across the top, a score in every cell (the Moodle
  "grader report"), built by `Athena.Learning.Gradebook`.

  Every filter, sort and display choice lives in the URL
  (`AthenaWeb.TeachingLive.GradebookParams`) - the filter form only ever
  `push_patch`es, and `handle_params/3` is the single place the table is
  rebuilt. The student/block pickers are native `popover`s inside that same
  form, so they stay open while the table refreshes behind them.

  This is the plain "scores only" mode: it never reads engagement data.
  """
  use AthenaWeb, :live_view

  alias Athena.{Content, Identity, Learning}
  alias AthenaWeb.TeachingLive.{GradebookParams, GradebookTable}
  import AthenaWeb.TeachingLive.CohortAnalyticsComponents, only: [analytics_tabs: 1]

  on_mount {AthenaWeb.Hooks.Permission, "grading.read"}

  @impl true
  def mount(%{"id" => cohort_id, "course_id" => course_id}, _session, socket) do
    user = socket.assigns.current_user

    with {:ok, cohort} <- Learning.get_cohort(user, cohort_id),
         {:ok, course} <- Content.get_course(course_id) do
      {:ok,
       socket
       |> assign(:cohort, cohort)
       |> assign(:course, course)
       |> assign(:can_open_submissions?, Identity.can?(user, "grading.update"))
       |> assign(:student_q, "")
       |> assign(:block_q, "")
       |> assign(:page_title, gettext("Gradebook: %{course}", course: course.title))}
    else
      _ ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Access denied or course not found."))
         |> push_navigate(to: ~p"/teaching/cohorts")}
    end
  end

  @impl true
  def handle_params(params, _url, socket) do
    filters = GradebookParams.parse(params)

    gradebook =
      Learning.build_gradebook(socket.assigns.cohort, socket.assigns.course.id, %{
        block_ids: filters.block_ids,
        types: filters.types,
        account_ids: filters.account_ids,
        from: filters.from,
        to: filters.to,
        attempt: filters.attempt
      })

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> assign(:gradebook, gradebook)
     |> assign(:table, GradebookTable.prepare(gradebook, filters))}
  end

  @impl true
  def handle_event("filter", params, socket) do
    %{filters: filters, gradebook: gradebook} = socket.assigns

    new_filters = %{
      filters
      | account_ids:
          picked_ids(
            params["students"],
            Enum.map(gradebook.all_rows, & &1.id),
            filters.account_ids
          ),
        block_ids: picked_ids(params["blocks"], catalog_block_ids(gradebook), filters.block_ids),
        types: parse_types(params["types"], filters.types),
        from: params |> Map.get("from") |> parse_date(filters.from),
        to: params |> Map.get("to") |> parse_date(filters.to),
        status: pick(params, "status", filters, :status),
        attempt: pick(params, "attempt", filters, :attempt),
        threshold: pick(params, "threshold", filters, :threshold),
        display: pick(params, "display", filters, :display),
        compact:
          if(Map.has_key?(params, "compact"), do: params["compact"] == "1", else: filters.compact)
    }

    {:noreply,
     socket
     |> assign(:student_q, params["student_q"] || socket.assigns.student_q)
     |> assign(:block_q, params["block_q"] || socket.assigns.block_q)
     |> patch_if_changed(new_filters)}
  end

  def handle_event("toggle_review", _params, socket) do
    status = if socket.assigns.filters.status == :review, do: :all, else: :review
    {:noreply, update_filters(socket, status: status)}
  end

  def handle_event("select_all_students", _params, socket),
    do: {:noreply, update_filters(socket, account_ids: nil)}

  def handle_event("clear_students", _params, socket),
    do: {:noreply, update_filters(socket, account_ids: [])}

  def handle_event("select_all_blocks", _params, socket),
    do: {:noreply, update_filters(socket, block_ids: nil, types: [])}

  def handle_event("clear_blocks", _params, socket),
    do: {:noreply, update_filters(socket, block_ids: [])}

  def handle_event("toggle_section", %{"section_id" => section_id}, socket) do
    %{filters: filters, gradebook: gradebook} = socket.assigns
    all_ids = catalog_block_ids(gradebook)
    selected = filters.block_ids || all_ids

    section_ids =
      for %{section: section, blocks: columns} <- gradebook.catalog,
          section.id == section_id,
          column <- columns,
          do: column.block.id

    new_selected =
      if Enum.all?(section_ids, &(&1 in selected)),
        do: selected -- section_ids,
        else: Enum.uniq(selected ++ section_ids)

    block_ids =
      if MapSet.new(new_selected) == MapSet.new(all_ids), do: nil, else: new_selected

    {:noreply, update_filters(socket, block_ids: block_ids)}
  end

  def handle_event("toggle_collapse", %{"section_id" => section_id}, socket) do
    collapsed = socket.assigns.filters.collapsed

    collapsed =
      if section_id in collapsed,
        do: List.delete(collapsed, section_id),
        else: [section_id | collapsed]

    {:noreply, update_filters(socket, collapsed: collapsed)}
  end

  def handle_event("collapse_all", _params, socket) do
    ids = Enum.map(socket.assigns.table.groups, & &1.section.id)
    {:noreply, update_filters(socket, collapsed: ids)}
  end

  def handle_event("expand_all", _params, socket),
    do: {:noreply, update_filters(socket, collapsed: [])}

  def handle_event("sort", %{"key" => key}, socket) do
    %{sort: sort, dir: dir} = socket.assigns.filters

    {sort, dir} =
      cond do
        key == sort -> {key, if(dir == :asc, do: :desc, else: :asc)}
        key == "name" -> {key, :asc}
        true -> {key, :desc}
      end

    {:noreply, update_filters(socket, sort: sort, dir: dir)}
  end

  def handle_event("reset", _params, socket) do
    {:noreply,
     socket
     |> assign(:student_q, "")
     |> assign(:block_q, "")
     |> push_patch(to: gradebook_path(socket, GradebookParams.defaults()))}
  end

  # A picker submits every ticked id plus an always-present "" sentinel
  # (so unticking everyone is still a submitted, empty list). Ticking all of
  # them means "no restriction" - `nil` - so the URL stays clean.
  defp picked_ids(nil, _all_ids, current), do: current

  defp picked_ids(values, all_ids, _current) do
    picked = values |> List.wrap() |> Enum.reject(&(&1 == ""))
    if MapSet.new(picked) == MapSet.new(all_ids), do: nil, else: picked
  end

  defp catalog_block_ids(gradebook) do
    for %{blocks: columns} <- gradebook.catalog, column <- columns, do: column.block.id
  end

  # Like `picked_ids/3`: the chips always submit a "" sentinel, so a missing
  # key means "this event didn't come from the filter form" - keep as is.
  defp parse_types(nil, current), do: current

  defp parse_types(values, _current) do
    values = values |> List.wrap() |> Enum.reject(&(&1 == ""))
    GradebookParams.parse(%{"types" => Enum.join(values, ",")}).types
  end

  defp parse_date(nil, current), do: current
  defp parse_date("", _current), do: nil
  defp parse_date(value, current), do: GradebookParams.parse(%{"from" => value}).from || current

  defp pick(params, key, filters, field) do
    case Map.fetch(params, key) do
      {:ok, value} -> Map.fetch!(GradebookParams.parse(%{key => value}), field)
      :error -> Map.fetch!(filters, field)
    end
  end

  defp update_filters(socket, changes) do
    patch_if_changed(socket, Map.merge(socket.assigns.filters, Map.new(changes)))
  end

  defp patch_if_changed(socket, filters) do
    if filters == socket.assigns.filters,
      do: socket,
      else: push_patch(socket, to: gradebook_path(socket, filters))
  end

  defp gradebook_path(socket, filters) do
    query = GradebookParams.to_query(filters)
    base = base_path(socket.assigns.cohort, socket.assigns.course)
    if query == %{}, do: base, else: base <> "?" <> URI.encode_query(query)
  end

  defp base_path(%{type: :team, id: id}, course),
    do: ~p"/teaching/teams/#{id}/gradebook/#{course.id}"

  defp base_path(%{id: id}, course), do: ~p"/teaching/cohorts/#{id}/gradebook/#{course.id}"

  defp export_path(socket_or_assigns, filters) do
    %{cohort: cohort, course: course} = assigns_of(socket_or_assigns)
    query = GradebookParams.to_query(filters)
    base = ~p"/teaching/cohorts/#{cohort.id}/gradebook/#{course.id}/export.csv"
    if query == %{}, do: base, else: base <> "?" <> URI.encode_query(query)
  end

  defp assigns_of(%{assigns: assigns}), do: assigns
  defp assigns_of(assigns), do: assigns

  defp cohort_show_path(%{type: :team, id: id}), do: ~p"/teaching/teams/#{id}"
  defp cohort_show_path(%{id: id}), do: ~p"/teaching/cohorts/#{id}"

  defp back_to_cohort_label(%{type: :team}), do: gettext("Back to Team")
  defp back_to_cohort_label(_cohort), do: gettext("Back to Cohort")

  # Render

  @impl true
  def render(assigns) do
    ~H"""
    <div id="gradebook-page" class="space-y-5 pb-16">
      <div class="flex flex-wrap items-end justify-between gap-4">
        <div class="min-w-0">
          <.link
            navigate={cohort_show_path(@cohort)}
            class="inline-flex items-center gap-2 text-xs font-bold uppercase tracking-widest text-base-content/50 hover:text-primary transition-colors mb-2"
          >
            <.icon name="hero-arrow-left" class="size-4" />
            {back_to_cohort_label(@cohort)}
          </.link>
          <h1 class="text-2xl font-black tracking-tight flex items-center gap-3">
            {gettext("Gradebook")}
            <.badge tone="primary">{@cohort.name}</.badge>
          </h1>
          <p class="text-sm text-base-content/60 truncate">{@course.title}</p>
        </div>

        <div class="flex flex-wrap items-center gap-2">
          <.analytics_tabs
            cohort={@cohort}
            course={@course}
            current_user={@current_user}
            active={:gradebook}
          />
          <.button
            id="gradebook-export"
            variant="ghost"
            size="sm"
            href={export_path(assigns, @filters)}
          >
            <.icon name="hero-arrow-down-tray" class="size-4" /> {gettext("Export CSV")}
          </.button>
        </div>
      </div>

      <.filter_bar
        filters={@filters}
        gradebook={@gradebook}
        student_q={@student_q}
        block_q={@block_q}
      />

      <.summary_strip table={@table} gradebook={@gradebook} filters={@filters} />

      <%= cond do %>
        <% @gradebook.catalog == [] -> %>
          <.empty_state
            icon="hero-table-cells"
            title={gettext("This course has no graded tasks yet.")}
          />
        <% @gradebook.all_rows == [] -> %>
          <.empty_state icon="hero-user-group" title={gettext("No students in this cohort yet.")} />
        <% @table.groups == [] or @table.rows == [] -> %>
          <div
            id="gradebook-no-results"
            class="bg-base-100 border border-base-200 rounded-sm p-10 text-center space-y-3"
          >
            <.icon name="hero-funnel" class="size-8 text-base-content/30 mx-auto" />
            <p class="font-bold">{gettext("Nothing matches the current filters.")}</p>
            <.button variant="ghost" size="sm" phx-click="reset">
              {gettext("Reset filters")}
            </.button>
          </div>
        <% true -> %>
          <.grade_table
            table={@table}
            gradebook={@gradebook}
            filters={@filters}
            can_open_submissions?={@can_open_submissions?}
          />
          <.legend filters={@filters} />
      <% end %>
    </div>
    """
  end

  attr :filters, :map, required: true
  attr :gradebook, :map, required: true
  attr :student_q, :string, required: true
  attr :block_q, :string, required: true

  defp filter_bar(assigns) do
    assigns = assign(assigns, :active_count, GradebookParams.active_count(assigns.filters))

    ~H"""
    <.form
      for={%{}}
      id="gradebook-filters"
      phx-change="filter"
      phx-submit="filter"
      class="bg-base-100 border border-base-200 rounded-sm p-3 flex flex-wrap items-end gap-3"
    >
      <.student_picker
        filters={@filters}
        rows={@gradebook.all_rows}
        query={@student_q}
      />
      <.block_picker filters={@filters} catalog={@gradebook.catalog} query={@block_q} />

      <div class="flex flex-col gap-1">
        <span class="filter-label">{gettext("Submitted")}</span>
        <div class="flex items-center gap-1.5 w-72">
          <.date_picker
            id="gradebook-from"
            name="from"
            value={@filters.from && Date.to_iso8601(@filters.from)}
            embedded
            placeholder={gettext("From")}
            class="input input-sm w-full"
          />
          <span class="text-base-content/40">—</span>
          <.date_picker
            id="gradebook-to"
            name="to"
            value={@filters.to && Date.to_iso8601(@filters.to)}
            min={@filters.from && Date.to_iso8601(@filters.from)}
            embedded
            placeholder={gettext("To")}
            class="input input-sm w-full"
          />
        </div>
      </div>

      <label class="flex flex-col gap-1">
        <span class="filter-label">{gettext("Status")}</span>
        <select id="gradebook-status" name="status" class="select select-sm rounded-sm w-48">
          <option
            :for={{value, label} <- status_options()}
            value={value}
            selected={@filters.status == value}
          >
            {label}
          </option>
        </select>
      </label>

      <label class="flex flex-col gap-1">
        <span class="filter-label">{gettext("Attempt")}</span>
        <select id="gradebook-attempt" name="attempt" class="select select-sm rounded-sm w-36">
          <option
            :for={{value, label} <- attempt_options()}
            value={value}
            selected={@filters.attempt == value}
          >
            {label}
          </option>
        </select>
      </label>

      <label class="flex flex-col gap-1">
        <span class="filter-label">{gettext("Pass mark")}</span>
        <select id="gradebook-threshold" name="threshold" class="select select-sm rounded-sm w-24">
          <option
            :for={value <- GradebookParams.thresholds()}
            value={value}
            selected={@filters.threshold == value}
          >
            {value}
          </option>
        </select>
      </label>

      <div class="flex flex-col gap-1">
        <span class="filter-label">{gettext("Display as")}</span>
        <div class="join" role="radiogroup">
          <label
            :for={{value, label, icon} <- display_options()}
            class={[
              "join-item btn btn-sm rounded-sm gap-1 cursor-pointer",
              if(@filters.display == value, do: "btn-primary", else: "btn-ghost border-base-300")
            ]}
          >
            <input
              type="radio"
              name="display"
              value={value}
              checked={@filters.display == value}
              class="sr-only"
            />
            <.icon name={icon} class="size-4" /> {label}
          </label>
        </div>
      </div>

      <label
        :if={@filters.status != :all}
        class="flex items-center gap-2 h-8 text-sm cursor-pointer select-none"
      >
        <input type="hidden" name="compact" value="0" />
        <input
          id="gradebook-compact"
          type="checkbox"
          name="compact"
          value="1"
          checked={@filters.compact}
          class="checkbox checkbox-sm checkbox-primary"
        />
        {gettext("Hide tasks with no matches")}
      </label>

      <button
        :if={@active_count > 0}
        id="gradebook-reset"
        type="button"
        phx-click="reset"
        class="btn btn-sm btn-ghost text-error ml-auto gap-1.5"
      >
        <.icon name="hero-x-mark" class="size-4" />
        {gettext("Reset filters")}
        <span class="badge badge-sm badge-error badge-soft">{@active_count}</span>
      </button>
    </.form>
    """
  end

  attr :filters, :map, required: true
  attr :rows, :list, required: true
  attr :query, :string, required: true

  defp student_picker(assigns) do
    selected = assigns.filters.account_ids

    assigns =
      assigns
      |> assign(:selected?, fn id -> is_nil(selected) or id in selected end)
      |> assign(:label, picker_label(selected, length(assigns.rows), gettext("All students")))
      |> assign(:needle, String.downcase(String.trim(assigns.query)))

    ~H"""
    <div class="flex flex-col gap-1">
      <span class="filter-label">{gettext("Students")}</span>
      <button
        id="gradebook-students-trigger"
        type="button"
        popovertarget="gradebook-students-popover"
        style="anchor-name: --gradebook-students"
        class={[
          "btn btn-sm rounded-sm w-48 justify-between font-normal",
          if(@filters.account_ids, do: "btn-primary btn-soft", else: "btn-ghost border-base-300")
        ]}
      >
        <span class="truncate">{@label}</span>
        <.icon name="hero-chevron-down" class="size-4 opacity-60" />
      </button>
      <div
        popover
        id="gradebook-students-popover"
        style="position-anchor: --gradebook-students"
        class="dropdown bg-base-100 rounded-sm border border-base-300 shadow-xl p-3 mt-1 w-80"
      >
        <input
          id="gradebook-student-search"
          type="search"
          name="student_q"
          value={@query}
          phx-debounce="150"
          autocomplete="off"
          placeholder={gettext("Search by name or login")}
          class="input input-sm w-full mb-2"
        />
        <div class="flex items-center justify-between text-xs mb-2">
          <button type="button" phx-click="select_all_students" class="link link-primary">
            {gettext("Select all")}
          </button>
          <button type="button" phx-click="clear_students" class="link link-hover">
            {gettext("Clear")}
          </button>
        </div>
        <input type="hidden" name="students[]" value="" />
        <div class="max-h-72 overflow-y-auto -mx-1">
          <label
            :for={row <- @rows}
            class={[
              "flex items-center gap-2 px-1 py-1.5 rounded-sm hover:bg-base-200 cursor-pointer",
              !matches_needle?(row, @needle) && "hidden"
            ]}
          >
            <input
              type="checkbox"
              name="students[]"
              value={row.id}
              checked={@selected?.(row.id)}
              class="checkbox checkbox-xs checkbox-primary"
            />
            <span class="truncate text-sm">{row.name}</span>
            <span
              :if={row.login && row.login != row.name}
              class="text-xs text-base-content/40 truncate"
            >
              {row.login}
            </span>
          </label>
        </div>
      </div>
    </div>
    """
  end

  attr :filters, :map, required: true
  attr :catalog, :list, required: true
  attr :query, :string, required: true

  defp block_picker(assigns) do
    selected = assigns.filters.block_ids
    total = Enum.sum(Enum.map(assigns.catalog, &length(&1.blocks)))

    assigns =
      assigns
      |> assign(:selected?, fn id -> is_nil(selected) or id in selected end)
      |> assign(:label, block_picker_label(assigns.filters, total))
      |> assign(:needle, String.downcase(String.trim(assigns.query)))

    ~H"""
    <div class="flex flex-col gap-1">
      <span class="filter-label">{gettext("Tasks")}</span>
      <button
        id="gradebook-blocks-trigger"
        type="button"
        popovertarget="gradebook-blocks-popover"
        style="anchor-name: --gradebook-blocks"
        class={[
          "btn btn-sm rounded-sm w-48 justify-between font-normal",
          if(@filters.block_ids || @filters.types != [],
            do: "btn-primary btn-soft",
            else: "btn-ghost border-base-300"
          )
        ]}
      >
        <span class="truncate">{@label}</span>
        <.icon name="hero-chevron-down" class="size-4 opacity-60" />
      </button>
      <div
        popover
        id="gradebook-blocks-popover"
        style="position-anchor: --gradebook-blocks"
        class="dropdown bg-base-100 rounded-sm border border-base-300 shadow-xl p-3 mt-1 w-[26rem]"
      >
        <div class="filter-label mb-1.5">{gettext("Task type")}</div>
        <input type="hidden" name="types[]" value="" />
        <div class="flex flex-wrap gap-1.5 mb-3">
          <label
            :for={type <- GradebookParams.types()}
            class={[
              "badge badge-md gap-1 cursor-pointer select-none transition-colors",
              if(type in @filters.types,
                do: "badge-primary",
                else: "badge-ghost hover:bg-base-300"
              )
            ]}
          >
            <input
              type="checkbox"
              name="types[]"
              value={type}
              checked={type in @filters.types}
              class="sr-only"
            />
            <.icon name={GradebookTable.type_icon(type)} class="size-3.5" />
            {GradebookTable.type_label(type)}
          </label>
        </div>
        <input
          id="gradebook-block-search"
          type="search"
          name="block_q"
          value={@query}
          phx-debounce="150"
          autocomplete="off"
          placeholder={gettext("Search tasks")}
          class="input input-sm w-full mb-2"
        />
        <div class="flex items-center justify-between text-xs mb-2">
          <button type="button" phx-click="select_all_blocks" class="link link-primary">
            {gettext("Select all")}
          </button>
          <button type="button" phx-click="clear_blocks" class="link link-hover">
            {gettext("Clear")}
          </button>
        </div>
        <input type="hidden" name="blocks[]" value="" />
        <div class="max-h-80 overflow-y-auto -mx-1 space-y-2">
          <div :for={%{section: section, blocks: columns} <- @catalog}>
            <button
              type="button"
              phx-click="toggle_section"
              phx-value-section_id={section.id}
              class="flex items-center gap-2 w-full px-1 py-1 text-left text-xs font-black uppercase tracking-wider text-base-content/60 hover:text-primary"
            >
              <.icon
                name={section_check_icon(columns, @selected?)}
                class="size-4 shrink-0 text-primary"
              />
              <span class="truncate">{section.title}</span>
            </button>
            <label
              :for={column <- columns}
              class={[
                "flex items-center gap-2 pl-6 pr-1 py-1 rounded-sm hover:bg-base-200 cursor-pointer",
                !block_matches_needle?(column, @needle) && "hidden"
              ]}
            >
              <input
                type="checkbox"
                name="blocks[]"
                value={column.block.id}
                checked={@selected?.(column.block.id)}
                class="checkbox checkbox-xs checkbox-primary"
              />
              <.icon
                name={GradebookTable.type_icon(column.block.type)}
                class="size-4 text-base-content/50 shrink-0"
              />
              <span class="text-sm truncate">
                {column.number}. {GradebookTable.type_label(column.block.type)}
                <span :if={column.preview != ""} class="text-base-content/50">
                  — {column.preview}
                </span>
              </span>
            </label>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :table, :map, required: true
  attr :gradebook, :map, required: true
  attr :filters, :map, required: true

  defp summary_strip(assigns) do
    row_ids = Enum.map(assigns.table.rows, & &1.row.id)

    cells =
      for r <- row_ids, b <- assigns.table.block_ids, do: Map.get(assigns.gradebook.cells, {r, b})

    scores = for %{state: :scored, score: score} <- cells, do: score

    assigns =
      assigns
      |> assign(:shown_rows, length(row_ids))
      |> assign(
        :average,
        if(scores == [], do: nil, else: round(Enum.sum(scores) / length(scores)))
      )
      |> assign(:review_count, Enum.count(cells, &match?(%{state: :review}, &1)))
      |> assign(:failed_count, Enum.count(scores, &(&1 < assigns.filters.threshold)))

    ~H"""
    <div id="gradebook-summary" class="grid grid-cols-2 md:grid-cols-4 gap-3">
      <div class="summary-tile">
        <span class="summary-value">
          {@shown_rows}<span class="text-base-content/40 text-base font-bold">/{length(@gradebook.all_rows)}</span>
        </span>
        <span class="summary-label">{gettext("Students shown")}</span>
      </div>
      <div class="summary-tile">
        <span class="summary-value">{length(@table.block_ids)}</span>
        <span class="summary-label">{gettext("Tasks shown")}</span>
      </div>
      <div class="summary-tile">
        <span class={["summary-value", @average && band_text(@average, @filters.threshold)]}>
          {@average || "—"}
        </span>
        <span class="summary-label">{gettext("Average score")}</span>
      </div>
      <button
        type="button"
        id="gradebook-review-tile"
        phx-click="toggle_review"
        class={[
          "summary-tile text-left transition-colors hover:border-warning/50",
          @filters.status == :review && "border-warning! bg-warning/5"
        ]}
        title={gettext("Show only answers waiting for manual review")}
      >
        <span class={["summary-value", @review_count > 0 && "text-warning"]}>
          {@review_count}
        </span>
        <span class="summary-label">
          {gettext("Awaiting review")}
          <span :if={@failed_count > 0} class="normal-case tracking-normal font-medium text-error">
            · {ngettext("%{count} below pass mark", "%{count} below pass mark", @failed_count)}
          </span>
        </span>
      </button>
    </div>
    """
  end

  attr :table, :map, required: true
  attr :gradebook, :map, required: true
  attr :filters, :map, required: true
  attr :can_open_submissions?, :boolean, required: true

  defp grade_table(assigns) do
    ~H"""
    <div class="flex items-center justify-end gap-3 text-xs -mb-2">
      <button type="button" phx-click="collapse_all" class="link link-hover text-base-content/60">
        {gettext("Collapse all sections")}
      </button>
      <button type="button" phx-click="expand_all" class="link link-hover text-base-content/60">
        {gettext("Expand all")}
      </button>
    </div>
    <div class="bg-base-100 border border-base-200 rounded-sm overflow-auto max-h-[70vh] shadow-sm">
      <table id="gradebook" class="border-separate border-spacing-0 text-sm min-w-full">
        <thead>
          <tr>
            <th
              rowspan="2"
              class="sticky left-0 top-0 z-30 bg-base-100 border-b border-r border-base-200 px-3 py-2 text-left align-bottom min-w-60"
            >
              <div class="flex items-center gap-3 text-xs font-bold text-base-content/60">
                <.sort_button key="name" filters={@filters}>{gettext("Student")}</.sort_button>
                <.sort_button key="average" filters={@filters}>{gettext("Avg")}</.sort_button>
                <.sort_button key="passed" filters={@filters}>{gettext("Passed")}</.sort_button>
              </div>
            </th>
            <th
              :for={group <- @table.groups}
              colspan={if group.collapsed?, do: 1, else: length(group.columns)}
              class="sticky top-0 z-20 bg-base-100 border-b border-r border-base-200 px-2 py-1.5 text-left font-normal"
            >
              <button
                type="button"
                phx-click="toggle_collapse"
                phx-value-section_id={group.section.id}
                class="flex items-center gap-1 text-xs font-black uppercase tracking-wider text-base-content/60 hover:text-primary transition-colors max-w-64"
                title={
                  if group.collapsed?,
                    do: gettext("Expand section"),
                    else: gettext("Collapse section into one column")
                }
              >
                <.icon
                  name={if group.collapsed?, do: "hero-chevron-right", else: "hero-chevron-down"}
                  class="size-3.5 shrink-0"
                />
                <span class="truncate">{group.section.title}</span>
              </button>
            </th>
          </tr>
          <tr>
            <%= for group <- @table.groups do %>
              <%= if group.collapsed? do %>
                <th class="sticky top-8 z-20 bg-base-200/80 backdrop-blur border-b border-r border-base-200 px-2 py-1.5 text-xs font-bold text-base-content/60 text-center">
                  {gettext("Avg")}
                </th>
              <% else %>
                <th
                  :for={column <- group.columns}
                  id={"col-#{column.block.id}"}
                  class="sticky top-8 z-20 bg-base-100 border-b border-base-200 px-1 py-1.5 font-normal min-w-14"
                  title={column_tooltip(column)}
                >
                  <button
                    type="button"
                    phx-click="sort"
                    phx-value-key={"block:#{column.block.id}"}
                    class={[
                      "flex flex-col items-center gap-0.5 w-full rounded-sm px-1 py-0.5 hover:bg-base-200 transition-colors",
                      @filters.sort == "block:#{column.block.id}" && "text-primary"
                    ]}
                  >
                    <.icon name={GradebookTable.type_icon(column.block.type)} class="size-4" />
                    <span class="text-xs font-bold tabular-nums">
                      {column.number}<.sort_arrow
                        :if={@filters.sort == "block:#{column.block.id}"}
                        dir={@filters.dir}
                      />
                    </span>
                  </button>
                </th>
              <% end %>
            <% end %>
          </tr>
        </thead>
        <tbody>
          <tr :for={%{row: row, summary: summary} <- @table.rows} id={"row-#{row.id}"} class="group">
            <th
              scope="row"
              class="sticky left-0 z-10 bg-base-100 group-hover:bg-base-200 border-b border-r border-base-200 px-3 py-1.5 text-left font-normal transition-colors"
            >
              <div class="font-bold truncate max-w-56" title={row.login}>{row.name}</div>
              <div class="flex items-center gap-2 text-xs text-base-content/60">
                <span class={[
                  "tabular-nums font-bold",
                  summary.average && band_text(summary.average, @filters.threshold)
                ]}>
                  {format_average(summary.average)}
                </span>
                <span class="tabular-nums">{summary.passed}/{summary.total}</span>
                <span class="flex-1 h-1 rounded-full bg-base-200 overflow-hidden min-w-10">
                  <span
                    class="block h-full bg-success/70 rounded-full transition-all duration-500"
                    style={"width: #{percent(summary.passed, summary.total)}%"}
                  >
                  </span>
                </span>
              </div>
            </th>
            <%= for group <- @table.groups do %>
              <%= if group.collapsed? do %>
                <.section_cell
                  gradebook={@gradebook}
                  row={row}
                  group={group}
                  filters={@filters}
                />
              <% else %>
                <.grade_cell
                  :for={column <- group.columns}
                  cell={Map.get(@gradebook.cells, {row.id, column.block.id})}
                  row={row}
                  column={column}
                  filters={@filters}
                  can_open_submissions?={@can_open_submissions?}
                />
              <% end %>
            <% end %>
          </tr>
        </tbody>
        <tfoot>
          <tr>
            <th class="sticky left-0 bottom-0 z-30 bg-base-200 border-t border-r border-base-300 px-3 py-2 text-left text-xs font-black uppercase tracking-wider text-base-content/60">
              {gettext("Group average")}
            </th>
            <%= for group <- @table.groups do %>
              <%= if group.collapsed? do %>
                <td class="sticky bottom-0 z-20 bg-base-200 border-t border-r border-base-300 px-1 py-2 text-center text-xs">
                  {format_average(average_of_columns(@table, group))}
                </td>
              <% else %>
                <td
                  :for={column <- group.columns}
                  class="sticky bottom-0 z-20 bg-base-200 border-t border-base-300 px-1 py-2 text-center"
                >
                  <% summary = @table.column_summaries[column.block.id] %>
                  <div class={[
                    "text-xs font-bold tabular-nums",
                    summary.average && band_text(summary.average, @filters.threshold)
                  ]}>
                    {format_average(summary.average)}
                  </div>
                  <div
                    class="text-[10px] text-base-content/50 tabular-nums"
                    title={gettext("Share of students at or above the pass mark")}
                  >
                    {percent(summary.passed, summary.total)}%
                  </div>
                </td>
              <% end %>
            <% end %>
          </tr>
        </tfoot>
      </table>
    </div>
    """
  end

  attr :key, :string, required: true
  attr :filters, :map, required: true
  slot :inner_block, required: true

  defp sort_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="sort"
      phx-value-key={@key}
      class={[
        "inline-flex items-center gap-0.5 hover:text-primary transition-colors",
        @filters.sort == @key && "text-primary"
      ]}
    >
      {render_slot(@inner_block)}<.sort_arrow :if={@filters.sort == @key} dir={@filters.dir} />
    </button>
    """
  end

  attr :dir, :atom, required: true

  defp sort_arrow(assigns) do
    ~H"""
    <.icon
      name={if @dir == :asc, do: "hero-chevron-up-mini", else: "hero-chevron-down-mini"}
      class="size-3.5"
    />
    """
  end

  attr :cell, :map, default: nil
  attr :row, :map, required: true
  attr :column, :map, required: true
  attr :filters, :map, required: true
  attr :can_open_submissions?, :boolean, required: true

  defp grade_cell(assigns) do
    matches? =
      Athena.Learning.Gradebook.matches_status?(
        assigns.cell,
        assigns.filters.status,
        assigns.filters.threshold
      )

    assigns =
      assigns
      |> assign(:dimmed?, not matches?)
      |> assign(:href, cell_href(assigns.cell, assigns.can_open_submissions?))

    ~H"""
    <td
      id={"cell-#{@row.id}-#{@column.block.id}"}
      class={[
        "border-b border-base-200 p-0.5 text-center transition-opacity",
        @dimmed? && "opacity-25"
      ]}
    >
      <.cell_body
        cell={@cell}
        href={@href}
        filters={@filters}
        title={cell_tooltip(@cell, @row, @column)}
      />
    </td>
    """
  end

  attr :cell, :map, default: nil
  attr :href, :string, default: nil
  attr :filters, :map, required: true
  attr :title, :string, required: true

  defp cell_body(%{cell: nil} = assigns) do
    ~H"""
    <span class="grade-cell text-base-content/25" title={@title}>—</span>
    """
  end

  defp cell_body(%{cell: %{state: :scored}} = assigns) do
    assigns =
      assign(assigns, :band, GradebookTable.band(assigns.cell.score, assigns.filters.threshold))

    ~H"""
    <.maybe_link
      href={@href}
      title={@title}
      class={[
        "grade-cell",
        band_cell(@band),
        @cell.status == :rejected && "line-through decoration-2"
      ]}
    >
      <%= if @filters.display == :pass do %>
        <.icon
          name={if @band == :fail, do: "hero-x-mark-mini", else: "hero-check-mini"}
          class="size-4"
        />
      <% else %>
        <span class="tabular-nums font-bold">{@cell.score}</span>
      <% end %>
      <sup :if={@cell.attempts > 1} class="text-[9px] font-normal opacity-60 -ml-0.5">
        ×{@cell.attempts}
      </sup>
    </.maybe_link>
    """
  end

  defp cell_body(%{cell: %{state: :review}} = assigns) do
    ~H"""
    <.maybe_link
      href={@href}
      title={@title}
      class="grade-cell border border-dashed border-warning/60 text-warning bg-warning/5"
    >
      <.icon name="hero-eye-mini" class="size-4" />
    </.maybe_link>
    """
  end

  defp cell_body(%{cell: %{state: :in_progress}} = assigns) do
    ~H"""
    <.maybe_link href={@href} title={@title} class="grade-cell text-info">
      <.icon name="hero-ellipsis-horizontal-mini" class="size-4" />
    </.maybe_link>
    """
  end

  attr :href, :string, default: nil
  attr :title, :string, required: true
  attr :class, :any, default: nil
  slot :inner_block, required: true

  defp maybe_link(%{href: nil} = assigns) do
    ~H"""
    <span class={@class} title={@title}>{render_slot(@inner_block)}</span>
    """
  end

  defp maybe_link(assigns) do
    ~H"""
    <.link
      navigate={@href}
      class={[@class, "hover:ring-2 hover:ring-primary/40 hover:scale-105"]}
      title={@title}
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end

  attr :gradebook, :map, required: true
  attr :row, :map, required: true
  attr :group, :map, required: true
  attr :filters, :map, required: true

  defp section_cell(assigns) do
    block_ids = Enum.map(assigns.group.columns, & &1.block.id)

    summary =
      Athena.Learning.Gradebook.row_summary(
        assigns.gradebook,
        assigns.row.id,
        block_ids,
        assigns.filters.threshold
      )

    assigns = assign(assigns, :summary, summary)

    ~H"""
    <td class="border-b border-r border-base-200 p-0.5 text-center bg-base-200/30">
      <span
        class={[
          "grade-cell",
          @summary.average &&
            band_cell(GradebookTable.band(round(@summary.average), @filters.threshold))
        ]}
        title={
          gettext("%{section}: average %{avg}, passed %{passed} of %{total}",
            section: @group.section.title,
            avg: format_average(@summary.average),
            passed: @summary.passed,
            total: @summary.total
          )
        }
      >
        <span class="tabular-nums font-bold">{format_average(@summary.average)}</span>
      </span>
    </td>
    """
  end

  attr :filters, :map, required: true

  defp legend(assigns) do
    ~H"""
    <div
      id="gradebook-legend"
      class="flex flex-wrap items-center gap-x-5 gap-y-2 text-xs text-base-content/60"
    >
      <span class="flex items-center gap-1.5">
        <span class={["grade-cell w-7! h-5!", band_cell(:excellent)]}></span>
        {gettext("%{score} and above", score: max(@filters.threshold, 85))}
      </span>
      <span class="flex items-center gap-1.5">
        <span class={["grade-cell w-7! h-5!", band_cell(:pass)]}></span>
        {gettext("Passed (%{score}+)", score: @filters.threshold)}
      </span>
      <span class="flex items-center gap-1.5">
        <span class={["grade-cell w-7! h-5!", band_cell(:fail)]}></span>
        {gettext("Below pass mark")}
      </span>
      <span class="flex items-center gap-1.5">
        <.icon name="hero-eye-mini" class="size-4 text-warning" /> {gettext("Awaiting review")}
      </span>
      <span class="flex items-center gap-1.5">
        <.icon name="hero-ellipsis-horizontal-mini" class="size-4 text-info" /> {gettext(
          "Being checked"
        )}
      </span>
      <span class="flex items-center gap-1.5">
        <span class="text-base-content/30 font-bold">—</span> {gettext("Not started")}
      </span>
      <span class="flex items-center gap-1.5">
        <span class="font-bold">80<sup class="text-[9px] opacity-60">×3</sup></span>
        {gettext("number of attempts")}
      </span>
      <span class="flex items-center gap-1.5">
        <span class="font-bold line-through decoration-2">40</span> {gettext("Rejected by teacher")}
      </span>
    </div>
    """
  end

  # View helpers

  defp status_options do
    [
      {:all, gettext("All results")},
      {:failed, gettext("Below pass mark")},
      {:review, gettext("Awaiting review")},
      {:not_started, gettext("Not started")},
      {:in_progress, gettext("Being checked")}
    ]
  end

  defp attempt_options do
    [
      {:best, gettext("Best attempt")},
      {:last, gettext("Last attempt")},
      {:first, gettext("First attempt")}
    ]
  end

  defp display_options do
    [
      {:score, gettext("Scores"), "hero-hashtag"},
      {:pass, gettext("Pass / fail"), "hero-check-circle"}
    ]
  end

  defp picker_label(nil, total, all_label), do: "#{all_label} (#{total})"
  defp picker_label([], _total, _all_label), do: gettext("None selected")

  defp picker_label(selected, total, _all_label),
    do: gettext("%{count} of %{total}", count: length(selected), total: total)

  defp block_picker_label(%{block_ids: nil, types: []}, total),
    do: "#{gettext("All tasks")} (#{total})"

  defp block_picker_label(%{block_ids: nil, types: types}, _total),
    do: Enum.map_join(types, ", ", &GradebookTable.type_label/1)

  defp block_picker_label(%{block_ids: ids}, total), do: picker_label(ids, total, "")

  defp section_check_icon(columns, selected?) do
    selected = Enum.count(columns, &selected?.(&1.block.id))

    cond do
      selected == length(columns) -> "hero-check-circle-solid"
      selected == 0 -> "hero-stop"
      true -> "hero-minus-circle"
    end
  end

  defp matches_needle?(_row, ""), do: true

  defp matches_needle?(row, needle) do
    String.contains?(String.downcase(row.name), needle) or
      String.contains?(String.downcase(row.login || ""), needle)
  end

  defp block_matches_needle?(_column, ""), do: true

  defp block_matches_needle?(column, needle) do
    [column.section.title, column.preview, GradebookTable.type_label(column.block.type)]
    |> Enum.any?(&String.contains?(String.downcase(&1 || ""), needle))
  end

  defp column_tooltip(column) do
    case column.preview do
      "" -> GradebookTable.column_title(column)
      preview -> GradebookTable.column_title(column) <> "\n" <> preview
    end
  end

  defp cell_tooltip(nil, row, column),
    do: "#{row.name} · #{GradebookTable.column_title(column)}\n#{gettext("Not started")}"

  defp cell_tooltip(cell, row, column) do
    state =
      case cell.state do
        :scored -> gettext("Score: %{score} / 100", score: cell.score)
        :review -> gettext("Awaiting review")
        :in_progress -> gettext("Being checked")
      end

    submitted =
      cell.submitted_at
      |> Athena.TimeZones.to_app_zone()
      |> Calendar.strftime("%d.%m.%Y %H:%M")

    [
      "#{row.name} · #{GradebookTable.column_title(column)}",
      state,
      ngettext("%{count} attempt", "%{count} attempts", cell.attempts),
      gettext("Submitted %{at}", at: submitted)
    ]
    |> Enum.join("\n")
  end

  defp cell_href(nil, _can_open?), do: nil
  defp cell_href(_cell, false), do: nil
  defp cell_href(cell, true), do: ~p"/teaching/grading/#{cell.submission_id}"

  defp average_of_columns(table, group) do
    averages =
      for column <- group.columns,
          avg = table.column_summaries[column.block.id].average,
          avg != nil,
          do: avg

    if averages == [], do: nil, else: Enum.sum(averages) / length(averages)
  end

  defp format_average(nil), do: "—"
  defp format_average(value), do: value |> round() |> Integer.to_string()

  defp percent(_part, 0), do: 0
  defp percent(part, total), do: round(part / total * 100)

  defp band_cell(:excellent), do: "bg-success/25 text-success-content"
  defp band_cell(:pass), do: "bg-success/10 text-base-content"
  defp band_cell(:fail), do: "bg-error/15 text-error"

  defp band_text(score, threshold) do
    case GradebookTable.band(round(score), threshold) do
      :fail -> "text-error"
      :excellent -> "text-success"
      :pass -> nil
    end
  end
end
