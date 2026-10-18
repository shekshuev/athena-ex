defmodule AthenaWeb.StudioLive.SurveyResults do
  @moduledoc """
  What students said: the results screen for one survey.

  A dedicated route rather than a pane beside the survey list, which is what
  the plan sketched. Frequencies, descriptives, crosstabs, a correlation
  matrix, reliability and verbatims do not fit alongside a list, and this
  screen is a destination someone links a colleague to.

  Four tabs, with the tab and the cohort filter held in the URL so any view of
  the results can be bookmarked or sent on - the same arrangement
  `AthenaWeb.TeachingLive.CohortEngagement` uses, and for the same reason.

  Nothing is computed on the dead render: a results page is several
  aggregations over every answer, and running them for a connection that is
  about to be replaced by the live one doubles the cost of every page view.

  ## Identity

  Every respondent reference on this screen comes from
  `Athena.Surveys.Results.respondent_labels/1`. A response that reached the
  survey through a cohort is shown as its cohort and an opaque number; only an
  individually enrolled respondent is named. This LiveView does not re-derive
  that rule and must not: it is one function so that it cannot be
  re-implemented slightly differently per view.
  """

  use AthenaWeb, :live_view

  import AthenaWeb.SurveyComponents, only: [prompt_text: 1]

  alias Athena.Identity
  alias Athena.Learning
  alias Athena.Surveys
  alias Athena.Surveys.QuestionTypes
  alias Athena.Surveys.Stats
  alias AthenaWeb.StudioLive.SurveyChartConfig, as: Charts

  on_mount {AthenaWeb.Hooks.Permission, ["surveys.results.read", "surveys.read"]}

  @tabs ~w(overview questions compare verbatims)

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Surveys.get_survey(id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Survey not found."))
         |> push_navigate(to: ~p"/studio/surveys")}

      survey ->
        if Identity.can?(socket.assigns.current_user, "surveys.read", survey) do
          {:ok,
           assign(socket,
             survey: survey,
             page_title: gettext("Results: %{title}", title: survey.title),
             loaded?: false,
             questions: [],
             cohorts: [],
             crosstab_with: nil
           )}
        else
          {:ok,
           socket
           |> put_flash(:error, gettext("You cannot read this survey's results."))
           |> push_navigate(to: ~p"/studio/surveys")}
        end
    end
  end

  @impl true
  def handle_params(params, _url, socket) do
    tab = if params["tab"] in @tabs, do: params["tab"], else: "overview"
    cohort_id = params["cohort_id"]
    focus = params["question_id"]

    socket = assign(socket, tab: tab, cohort_id: cohort_id, focus_id: focus)

    # Only once the socket is live: this page is several aggregations over
    # every answer, and doing them twice per visit is a waste that grows with
    # the response count.
    if connected?(socket) do
      {:noreply, load_results(socket)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("select_tab", %{"tab" => tab}, socket) do
    {:noreply, push_patch(socket, to: results_path(socket, %{"tab" => tab}))}
  end

  def handle_event("filter_cohort", %{"cohort_id" => cohort_id}, socket) do
    cohort_id = if cohort_id == "", do: nil, else: cohort_id

    {:noreply, push_patch(socket, to: results_path(socket, %{"cohort_id" => cohort_id}))}
  end

  def handle_event("focus_question", %{"question_id" => question_id}, socket) do
    {:noreply, push_patch(socket, to: results_path(socket, %{"question_id" => question_id}))}
  end

  def handle_event("crosstab_with", %{"question_id" => question_id}, socket) do
    with %{} = focus <- focus_question(socket),
         %{} = other <- Enum.find(socket.assigns.questions, &(&1.id == question_id)) do
      {:noreply,
       assign(socket,
         crosstab_with: question_id,
         crosstab: Surveys.crosstab(focus, other, scope(socket))
       )}
    else
      _ -> {:noreply, assign(socket, crosstab_with: nil, crosstab: nil)}
    end
  end

  def handle_event("refresh", _params, socket) do
    {:noreply, load_results(socket)}
  end

  # -- render ---------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.page_container size="wide">
        <.sticky_header>
          <div class="flex flex-wrap items-end justify-between gap-4">
            <div class="min-w-0">
              <.link
                navigate={~p"/studio/surveys"}
                class="mb-2 inline-flex items-center gap-1 text-sm text-base-content/60 hover:text-base-content"
              >
                <.icon name="hero-arrow-left" class="size-4" />
                {gettext("All surveys")}
              </.link>
              <h1 class="font-display text-2xl font-black">{@survey.title}</h1>
              <p class="mt-1 text-sm text-base-content/60">
                {gettext("Answers from a cohort are reported by cohort, never by name.")}
              </p>
            </div>

            <div class="flex flex-wrap items-center gap-2">
              <form :if={@cohorts != []} phx-change="filter_cohort">
                <select name="cohort_id" id="cohort-filter" class="select select-bordered select-sm">
                  <option value="">{gettext("All respondents")}</option>
                  <option :for={{name, id} <- @cohorts} value={id} selected={@cohort_id == id}>
                    {name}
                  </option>
                </select>
              </form>
              <.button size="sm" phx-click="refresh" id="refresh-results">
                <.icon name="hero-arrow-path" class="size-4" />
                {gettext("Refresh")}
              </.button>
              <div
                :if={Identity.can?(@current_user, "surveys.results.export")}
                class="dropdown dropdown-end"
              >
                <div tabindex="0" role="button" class="btn btn-outline btn-sm" id="export-menu">
                  <.icon name="hero-arrow-down-tray" class="size-4" />
                  {gettext("Download")}
                </div>
                <ul class="dropdown-content menu z-20 w-64 rounded-lg border border-base-300 bg-base-100 p-2 shadow-xl">
                  <li>
                    <a href={export_path(@survey, @cohort_id, :wide)} id="export-wide">
                      <div>
                        <p class="font-bold">{gettext("Spreadsheet")}</p>
                        <p class="text-xs text-base-content/60">
                          {gettext("One row per person, one column per question")}
                        </p>
                      </div>
                    </a>
                  </li>
                  <li>
                    <a href={export_path(@survey, @cohort_id, :long)} id="export-long">
                      <div>
                        <p class="font-bold">{gettext("For SPSS or R")}</p>
                        <p class="text-xs text-base-content/60">
                          {gettext("One row per answer, with codes and labels")}
                        </p>
                      </div>
                    </a>
                  </li>
                </ul>
              </div>
              <.button size="sm" navigate={~p"/studio/surveys/#{@survey.id}/builder"}>
                {gettext("Open builder")}
              </.button>
            </div>
          </div>
        </.sticky_header>

        <div :if={!@loaded?} class="py-16 text-center">
          <.spinner class="mx-auto size-6" />
        </div>

        <div :if={@loaded?}>
          <div :if={@summary.started == 0} id="no-responses">
            <.empty_state
              icon="hero-inbox"
              title={gettext("Nobody has answered yet")}
              description={
                gettext(
                  "Once students start answering, their replies show up here as they go - you do not have to wait for anyone to finish."
                )
              }
            />
          </div>

          <div :if={@summary.started > 0} class="space-y-8">
            <div class="grid grid-cols-2 gap-4 sm:grid-cols-4">
              <.stat_card label={gettext("Started")} value={@summary.started} />
              <.stat_card label={gettext("Finished")} value={@summary.completed} />
              <.stat_card
                label={gettext("Finished share")}
                value={percent(@summary.completion_rate)}
              />
              <.stat_card label={gettext("Cohorts")} value={@summary.cohort_count} />
            </div>

            <div role="tablist" class="tabs tabs-bordered">
              <button
                :for={{tab, label} <- tabs()}
                type="button"
                role="tab"
                phx-click="select_tab"
                phx-value-tab={tab}
                id={"tab-#{tab}"}
                class={["tab", @tab == tab && "tab-active font-bold"]}
              >
                {label}
              </button>
            </div>

            <%= case @tab do %>
              <% "overview" -> %>
                <.overview_tab funnel={@funnel} summary={@summary} />
              <% "questions" -> %>
                <.questions_tab
                  questions={@questions}
                  focus={@focus}
                  frequencies={@frequencies}
                  descriptives={@descriptives}
                  nps={@nps}
                  matrix={@matrix}
                  reliability={@reliability}
                  crosstab={@crosstab}
                  crosstab_with={@crosstab_with}
                />
              <% "compare" -> %>
                <.compare_tab
                  questions={@questions}
                  focus={@focus}
                  comparison={@comparison}
                  correlations={@correlations}
                />
              <% "verbatims" -> %>
                <.verbatims_tab questions={@questions} focus={@focus} verbatims={@verbatims} />
            <% end %>
          </div>
        </div>
      </.page_container>
    </div>
    """
  end

  defp tabs do
    [
      {"overview", gettext("Overview")},
      {"questions", gettext("Questions")},
      {"compare", gettext("Compare")},
      {"verbatims", gettext("In their words")}
    ]
  end

  # -- overview -------------------------------------------------------------

  attr :funnel, :list, required: true
  attr :summary, :map, required: true

  defp overview_tab(assigns) do
    ~H"""
    <div class="space-y-6">
      <section class="rounded-xl border border-base-300 bg-base-100 p-6">
        <h2 class="font-display font-bold">{gettext("Where people stopped")}</h2>
        <p class="mt-1 mb-5 text-sm text-base-content/60">
          {gettext(
            "The question where the line drops is the one to look at: too long, too personal, or badly worded."
          )}
        </p>
        <.chart id="funnel-chart" config={Charts.funnel_config(@funnel)} class="h-64" />
      </section>

      <section class="overflow-x-auto rounded-xl border border-base-300 bg-base-100">
        <table class="table table-sm">
          <thead>
            <tr>
              <th>#</th>
              <th>{gettext("Question")}</th>
              <th class="text-right">{gettext("Answered")}</th>
              <th class="text-right">{gettext("Declined")}</th>
              <th class="text-right">{gettext("Never reached")}</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={{step, index} <- Enum.with_index(@funnel, 1)}>
              <td class="tabular-nums text-base-content/40">{index}</td>
              <td class="max-w-md">
                <button
                  type="button"
                  phx-click="focus_question"
                  phx-value-question_id={step.question.id}
                  class="link link-hover text-left"
                >
                  {short_prompt(step.question)}
                </button>
                <span class="ml-2 text-xs text-base-content/40">
                  {type_label(step.question.type)}
                </span>
              </td>
              <td class="text-right tabular-nums font-medium">{step.answered}</td>
              <td class="text-right tabular-nums">{step.skipped}</td>
              <td class="text-right tabular-nums text-base-content/50">{step.not_reached}</td>
            </tr>
          </tbody>
        </table>
      </section>
    </div>
    """
  end

  # -- questions ------------------------------------------------------------

  attr :questions, :list, required: true
  attr :focus, :map, default: nil
  attr :frequencies, :any, default: nil
  attr :descriptives, :any, default: nil
  attr :nps, :any, default: nil
  attr :matrix, :any, default: nil
  attr :reliability, :any, default: nil
  attr :crosstab, :any, default: nil
  attr :crosstab_with, :any, default: nil

  defp questions_tab(assigns) do
    ~H"""
    <div class="grid gap-6 lg:grid-cols-[18rem_1fr]">
      <.question_list questions={@questions} focus={@focus} />

      <div :if={@focus} class="min-w-0 space-y-6">
        <header>
          <h2 class="font-display text-lg font-bold">{short_prompt(@focus)}</h2>
          <p class="mt-0.5 text-xs text-base-content/50">
            {type_label(@focus.type)} · {measurement_label(@focus.type)}
          </p>
        </header>

        <section :if={match?({:ok, _}, @frequencies)} class="space-y-4">
          <% {:ok, frequencies} = @frequencies %>
          <.chart
            :if={@focus.type != :multi_scale}
            id="frequency-chart"
            config={Charts.frequency_bar_config(frequencies)}
            class="h-64"
          />
          <.frequency_table frequencies={frequencies} />
        </section>

        <section :if={match?({:ok, _}, @matrix)} class="space-y-4">
          <% {:ok, matrix} = @matrix %>
          <h3 class="font-bold">{gettext("Each item on the shared scale")}</h3>
          <.chart
            id="likert-chart"
            config={Charts.likert_stacked_config(matrix.row_labels, matrix.points, matrix.counts)}
            class="h-72"
          />
        </section>

        <section :if={match?({:ok, _}, @nps)} class="space-y-4">
          <% {:ok, nps} = @nps %>
          <div class="flex flex-wrap items-center gap-6 rounded-xl border border-base-300 bg-base-100 p-6">
            <div>
              <p class="font-display text-4xl font-black tabular-nums">
                {round(nps.score)}
              </p>
              <p class="text-xs uppercase tracking-wide text-base-content/50">
                {gettext("NPS")}
              </p>
            </div>
            <div class="h-40 min-w-56 flex-1">
              <.chart id="nps-chart" config={Charts.nps_doughnut_config(nps)} class="h-40" />
            </div>
          </div>
        </section>

        <.descriptives_panel :if={match?({:ok, _}, @descriptives)} descriptives={@descriptives} />

        <.reliability_panel :if={match?({:ok, _}, @reliability)} reliability={@reliability} />

        <.crosstab_panel
          :if={crosstabbable?(@focus)}
          focus={@focus}
          questions={@questions}
          crosstab={@crosstab}
          crosstab_with={@crosstab_with}
        />
      </div>
    </div>
    """
  end

  attr :questions, :list, required: true
  attr :focus, :map, default: nil

  defp question_list(assigns) do
    ~H"""
    <nav class="space-y-1 lg:sticky lg:top-24 lg:self-start">
      <button
        :for={{question, index} <- Enum.with_index(@questions, 1)}
        type="button"
        phx-click="focus_question"
        phx-value-question_id={question.id}
        id={"question-tab-#{question.id}"}
        class={[
          "flex w-full items-start gap-2 rounded-lg px-3 py-2 text-left text-sm transition-colors",
          if(@focus && @focus.id == question.id,
            do: "bg-primary/10 font-medium text-primary",
            else: "hover:bg-base-200/60"
          )
        ]}
      >
        <span class="w-5 shrink-0 tabular-nums text-base-content/40">{index}</span>
        <span class="min-w-0 flex-1 truncate">{short_prompt(question)}</span>
      </button>
    </nav>
    """
  end

  attr :frequencies, :map, required: true

  defp frequency_table(assigns) do
    ~H"""
    <div class="overflow-x-auto rounded-xl border border-base-300 bg-base-100">
      <table class="table table-sm">
        <thead>
          <tr>
            <th>{gettext("Answer")}</th>
            <th class="text-right">{gettext("Count")}</th>
            <th class="text-right">{gettext("Of those who answered")}</th>
            <th class="text-right">{gettext("Of everyone")}</th>
            <th :if={!@frequencies.multi_select?} class="text-right">
              {gettext("Cumulative")}
            </th>
          </tr>
        </thead>
        <tbody>
          <tr :for={row <- @frequencies.rows}>
            <td>{row.label}</td>
            <td class="text-right tabular-nums font-medium">{row.count}</td>
            <td class="text-right tabular-nums">{percent(row.valid_percent)}</td>
            <td class="text-right tabular-nums text-base-content/60">{percent(row.percent)}</td>
            <td :if={!@frequencies.multi_select?} class="text-right tabular-nums text-base-content/60">
              {percent(row.cumulative_percent)}
            </td>
          </tr>
        </tbody>
        <tfoot>
          <tr>
            <td class="text-base-content/60">{gettext("Answered")}</td>
            <td class="text-right tabular-nums">{@frequencies.valid}</td>
            <td colspan="3"></td>
          </tr>
          <tr :if={@frequencies.skipped > 0}>
            <td class="text-base-content/60">{gettext("Saw it and declined")}</td>
            <td class="text-right tabular-nums">{@frequencies.skipped}</td>
            <td colspan="3"></td>
          </tr>
        </tfoot>
      </table>
      <p :if={@frequencies.multi_select?} class="px-4 pb-4 text-xs text-base-content/50">
        {gettext("People could pick more than one, so these add to more than 100%.")}
      </p>
    </div>
    """
  end

  attr :descriptives, :any, required: true

  defp descriptives_panel(assigns) do
    ~H"""
    <% {:ok, stats} = @descriptives %>
    <section class="rounded-xl border border-base-300 bg-base-100 p-6">
      <h3 class="mb-4 font-bold">{gettext("Numbers")}</h3>

      <div :if={Map.has_key?(stats, :per_row)} class="overflow-x-auto">
        <table class="table table-sm">
          <thead>
            <tr>
              <th>{gettext("Item")}</th>
              <th class="text-right">{gettext("Answered")}</th>
              <th class="text-right">{gettext("Mean")}</th>
              <th class="text-right">{gettext("Median")}</th>
              <th class="text-right">{gettext("SD")}</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- stats.per_row}>
              <td>{row.label}</td>
              <td class="text-right tabular-nums">{row.n}</td>
              <td class="text-right tabular-nums font-medium">{number(row.mean)}</td>
              <td class="text-right tabular-nums">{number(row.median)}</td>
              <td class="text-right tabular-nums">{number(row.sd)}</td>
            </tr>
          </tbody>
        </table>
      </div>

      <dl :if={!Map.has_key?(stats, :per_row)} class="grid grid-cols-2 gap-x-6 gap-y-3 sm:grid-cols-4">
        <.figure label={gettext("Answered")} value={stats.n} />
        <.figure label={gettext("Mean")} value={number(stats.mean)} />
        <.figure label={gettext("Median")} value={number(stats.median)} />
        <.figure label={gettext("Mode")} value={modes_label(stats.modes)} />
        <.figure label={gettext("SD")} value={number(stats.sd)} />
        <.figure label={gettext("Std. error")} value={number(stats.se)} />
        <.figure label={gettext("Min / max")} value={"#{number(stats.min)} / #{number(stats.max)}"} />
        <.figure label={gettext("Quartiles")} value={"#{number(stats.q1)} / #{number(stats.q3)}"} />
        <.figure label={gettext("Skewness")} value={number(stats.skewness)} />
        <.figure label={gettext("Kurtosis")} value={number(stats.kurtosis)} />
      </dl>

      <%!-- A five-number summary instead of a box plot: Chart.js needs a
            plugin for one, and this is the same information. --%>
      <p
        :if={!Map.has_key?(stats, :per_row) && stats.skipped > 0}
        class="mt-4 text-xs text-base-content/50"
      >
        {ngettext(
          "%{count} person saw this and declined to answer.",
          "%{count} people saw this and declined to answer.",
          stats.skipped,
          count: stats.skipped
        )}
      </p>
    </section>
    """
  end

  attr :reliability, :any, required: true

  defp reliability_panel(assigns) do
    ~H"""
    <% {:ok, result} = @reliability %>
    <section class="rounded-xl border border-base-300 bg-base-100 p-6">
      <h3 class="font-bold">{gettext("Do these items measure one thing?")}</h3>
      <p class="mt-1 mb-4 text-sm text-base-content/60">
        {gettext("Cronbach's alpha: above 0.7 the items hang together well enough to average.")}
      </p>

      <div class="mb-4 flex items-baseline gap-3">
        <span class="font-display text-3xl font-black tabular-nums">{number(result.alpha)}</span>
        <span class="text-sm text-base-content/60">
          {gettext("over %{items} items, %{n} respondents", items: result.item_count, n: result.n)}
        </span>
      </div>

      <p :if={result.dropped_incomplete > 0} class="mb-4 text-xs text-base-content/50">
        {ngettext(
          "%{count} respondent left a row blank and is not included: alpha describes how items hang together for the same people.",
          "%{count} respondents left a row blank and are not included: alpha describes how items hang together for the same people.",
          result.dropped_incomplete,
          count: result.dropped_incomplete
        )}
      </p>

      <div class="overflow-x-auto">
        <table class="table table-sm">
          <thead>
            <tr>
              <th>{gettext("Item")}</th>
              <th class="text-right">{gettext("Mean")}</th>
              <th class="text-right">{gettext("Correlation with the rest")}</th>
              <th class="text-right">{gettext("Alpha without it")}</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={{item, label} <- Enum.zip(result.items, result.row_labels)}>
              <td>{label}</td>
              <td class="text-right tabular-nums">{number(item.mean)}</td>
              <td class="text-right tabular-nums">{number(item.item_total_r)}</td>
              <td class={[
                "text-right tabular-nums",
                drags_down?(item, result.alpha) && "font-bold text-warning"
              ]}>
                {number(item.alpha_if_deleted)}
              </td>
            </tr>
          </tbody>
        </table>
      </div>
      <p class="mt-3 text-xs text-base-content/50">
        {gettext(
          "An item highlighted here would raise alpha if you dropped it - it is measuring something else."
        )}
      </p>
    </section>
    """
  end

  attr :focus, :map, required: true
  attr :questions, :list, required: true
  attr :crosstab, :any, default: nil
  attr :crosstab_with, :any, default: nil

  defp crosstab_panel(assigns) do
    ~H"""
    <section class="rounded-xl border border-base-300 bg-base-100 p-6">
      <h3 class="font-bold">{gettext("Cross-tabulate with another question")}</h3>
      <p class="mt-1 mb-4 text-sm text-base-content/60">
        {gettext("Does the answer to this question depend on the answer to another one?")}
      </p>

      <form phx-change="crosstab_with" class="mb-5">
        <select name="question_id" id="crosstab-select" class="select select-bordered select-sm">
          <option value="">{gettext("Choose a question")}</option>
          <option
            :for={question <- crosstab_candidates(@questions, @focus)}
            value={question.id}
            selected={@crosstab_with == question.id}
          >
            {short_prompt(question)}
          </option>
        </select>
      </form>

      <div :if={match?({:ok, _}, @crosstab)} class="space-y-4">
        <% {:ok, table} = @crosstab %>
        <div class="overflow-x-auto">
          <table class="table table-sm">
            <thead>
              <tr>
                <th></th>
                <th :for={label <- table.col_labels} class="text-right">{label}</th>
                <th class="text-right">{gettext("Total")}</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={{row, label} <- Enum.zip(table.table, table.row_labels)}>
                <th class="font-normal">{label}</th>
                <td :for={count <- row} class="text-right tabular-nums">{count}</td>
                <td class="text-right tabular-nums font-medium">{Enum.sum(row)}</td>
              </tr>
            </tbody>
            <tfoot>
              <tr>
                <th class="font-normal text-base-content/60">{gettext("Total")}</th>
                <td :for={total <- table.col_totals} class="text-right tabular-nums">{total}</td>
                <td class="text-right tabular-nums font-bold">{table.n}</td>
              </tr>
            </tfoot>
          </table>
        </div>

        <.test_result test={table.test} kind={:cramers_v} />
      </div>

      <p :if={match?({:error, _}, @crosstab)} class="text-sm text-base-content/60">
        {crosstab_error(@crosstab)}
      </p>
    </section>
    """
  end

  # -- compare --------------------------------------------------------------

  attr :questions, :list, required: true
  attr :focus, :map, default: nil
  attr :comparison, :any, default: nil
  attr :correlations, :any, default: nil

  defp compare_tab(assigns) do
    ~H"""
    <div class="grid gap-6 lg:grid-cols-[18rem_1fr]">
      <.question_list questions={@questions} focus={@focus} />

      <div class="min-w-0 space-y-6">
        <section class="rounded-xl border border-base-300 bg-base-100 p-6">
          <h3 class="font-bold">{gettext("Did the cohorts answer differently?")}</h3>

          <div :if={match?({:ok, %{kind: :quantitative}}, @comparison)} class="mt-5 space-y-5">
            <% {:ok, comparison} = @comparison %>
            <.chart
              id="group-means-chart"
              config={Charts.group_means_config(group_rows(comparison))}
              class="h-64"
            />

            <div class="overflow-x-auto">
              <table class="table table-sm">
                <thead>
                  <tr>
                    <th>{gettext("Group")}</th>
                    <th class="text-right">{gettext("Answered")}</th>
                    <th class="text-right">{gettext("Mean")}</th>
                    <th class="text-right">{gettext("SD")}</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={group <- comparison.groups}>
                    <td>{group_label(group.name)}</td>
                    <td class="text-right tabular-nums">{group.descriptives.n}</td>
                    <td class="text-right tabular-nums font-medium">
                      {number(group.descriptives.mean)}
                    </td>
                    <td class="text-right tabular-nums">{number(group.descriptives.sd)}</td>
                  </tr>
                </tbody>
              </table>
            </div>

            <%!-- Both tests, side by side. They almost always agree; when
                  they do not, the distribution is skewed enough that the
                  mean was the wrong summary, and that is worth seeing. --%>
            <div class="grid gap-4 sm:grid-cols-2">
              <.test_result test={comparison.parametric} kind={effect_kind(comparison.parametric)} />
              <.test_result test={comparison.nonparametric} kind={nil} />
            </div>
          </div>

          <div :if={match?({:ok, %{kind: :nominal}}, @comparison)} class="mt-5 space-y-4">
            <% {:ok, comparison} = @comparison %>
            <div class="overflow-x-auto">
              <table class="table table-sm">
                <thead>
                  <tr>
                    <th></th>
                    <th :for={label <- comparison.category_labels} class="text-right">{label}</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={{row, key} <- Enum.zip(comparison.table, comparison.group_keys)}>
                    <th class="font-normal">{group_label(comparison.group_names[key])}</th>
                    <td :for={count <- row} class="text-right tabular-nums">{count}</td>
                  </tr>
                </tbody>
              </table>
            </div>
            <.test_result test={comparison.test} kind={:cramers_v} />
          </div>

          <p :if={match?({:error, _}, @comparison)} class="mt-4 text-sm text-base-content/60">
            {comparison_error(@comparison)}
          </p>
        </section>

        <section
          :if={match?({:ok, _}, @correlations)}
          class="rounded-xl border border-base-300 bg-base-100 p-6"
        >
          <% {:ok, correlations} = @correlations %>
          <h3 class="font-bold">{gettext("Do answers move together?")}</h3>
          <p class="mt-1 mb-4 text-sm text-base-content/60">
            {gettext(
              "Pearson and Spearman side by side: on scale answers they can disagree, and the disagreement is informative."
            )}
          </p>
          <div class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>{gettext("Pair")}</th>
                  <th class="text-right">{gettext("Pairs")}</th>
                  <th class="text-right">{gettext("Pearson r")}</th>
                  <th class="text-right">{gettext("Spearman rho")}</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={pair <- correlations.pairs}>
                  <td class="max-w-md">
                    {short_prompt(pair.row)} <span class="text-base-content/40">+</span>
                    {short_prompt(pair.col)}
                  </td>
                  <td class="text-right tabular-nums">{pair.n}</td>
                  <td class="text-right tabular-nums">{coefficient(pair.pearson, :r)}</td>
                  <td class="text-right tabular-nums">{coefficient(pair.spearman, :rho)}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>
      </div>
    </div>
    """
  end

  # -- verbatims ------------------------------------------------------------

  attr :questions, :list, required: true
  attr :focus, :map, default: nil
  attr :verbatims, :any, default: nil

  defp verbatims_tab(assigns) do
    ~H"""
    <div class="grid gap-6 lg:grid-cols-[18rem_1fr]">
      <.question_list questions={@questions} focus={@focus} />

      <div class="min-w-0">
        <div :if={match?({:ok, _}, @verbatims)} class="space-y-3">
          <% {:ok, verbatims} = @verbatims %>
          <p class="text-sm text-base-content/60">
            {ngettext("%{count} answer", "%{count} answers", length(verbatims.entries),
              count: length(verbatims.entries)
            )}
          </p>

          <article
            :for={entry <- verbatims.entries}
            class="rounded-xl border border-base-300 bg-base-100 p-5"
          >
            <p class="whitespace-pre-wrap text-sm leading-relaxed">{entry.text}</p>
            <%!-- The label comes from `respondent_labels/1`; for a cohort
                  respondent it names the cohort and a number, never the
                  person, and no account id reaches the markup. --%>
            <p class="mt-3 text-xs text-base-content/40">{entry.label && entry.label.text}</p>
          </article>

          <.empty_state
            :if={verbatims.entries == []}
            icon="hero-chat-bubble-bottom-center-text"
            title={gettext("Nothing written yet")}
          />
        </div>

        <p :if={match?({:error, _}, @verbatims)} class="text-sm text-base-content/60">
          {gettext("This question has no written answers. Pick an open-text question.")}
        </p>
      </div>
    </div>
    """
  end

  # -- small pieces ---------------------------------------------------------

  attr :id, :string, required: true
  attr :config, :map, required: true
  attr :class, :any, default: "h-64"

  defp chart(assigns) do
    ~H"""
    <%!-- The existing engagement chart hook, reused: a survey chart is still
          a Chart.js config built on the server, so there is no new JS. --%>
    <div class={@class}>
      <canvas id={@id} phx-hook="EngagementChart" data-config={Jason.encode!(@config)}></canvas>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true

  defp stat_card(assigns) do
    ~H"""
    <div class="rounded-xl border border-base-300 bg-base-100 p-4">
      <p class="font-display text-2xl font-black tabular-nums">{@value}</p>
      <p class="mt-0.5 text-xs uppercase tracking-wide text-base-content/50">{@label}</p>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true

  defp figure(assigns) do
    ~H"""
    <div>
      <dt class="text-xs uppercase tracking-wide text-base-content/50">{@label}</dt>
      <dd class="font-medium tabular-nums">{@value}</dd>
    </div>
    """
  end

  attr :test, :any, required: true
  attr :kind, :atom, default: nil

  defp test_result(assigns) do
    ~H"""
    <div :if={match?({:ok, _}, @test)} class="rounded-lg bg-base-200/50 p-4 text-sm">
      <% {:ok, result} = @test %>
      <p class="font-bold">{test_name(result)}</p>
      <p class="mt-1 tabular-nums text-base-content/70">
        {test_statistic(result)} · p = {p_value(result.p)}
      </p>
      <p class="mt-1.5">
        {significance_sentence(result.p)}
      </p>
      <p :if={@kind && effect_value(result, @kind)} class="mt-1 text-xs text-base-content/60">
        {effect_sentence(@kind, effect_value(result, @kind))}
      </p>
      <p :if={Map.get(result, :small_expected_cells, 0) > 0} class="mt-2 text-xs text-warning">
        {ngettext(
          "%{count} cell has an expected count below 5, so treat this p-value with caution.",
          "%{count} cells have expected counts below 5, so treat this p-value with caution.",
          result.small_expected_cells,
          count: result.small_expected_cells
        )}
      </p>
    </div>
    <div
      :if={match?({:error, _}, @test)}
      class="rounded-lg bg-base-200/50 p-4 text-sm text-base-content/60"
    >
      {test_error(@test)}
    </div>
    """
  end

  # -- formatting -----------------------------------------------------------

  defp short_prompt(question) do
    case prompt_text(question.body) do
      "" -> gettext("Untitled question")
      text -> String.slice(text, 0, 70)
    end
  end

  defp percent(nil), do: "–"
  defp percent(value), do: "#{round(value * 100)}%"

  defp number(nil), do: "–"
  defp number(value) when is_integer(value), do: Integer.to_string(value)

  defp number(value) when is_float(value) do
    value |> Float.round(2) |> :erlang.float_to_binary(decimals: 2)
  end

  defp number(value), do: to_string(value)

  defp modes_label([]), do: "–"
  defp modes_label(modes), do: Enum.map_join(modes, ", ", &number/1)

  defp p_value(nil), do: "–"
  defp p_value(p) when p < 0.001, do: "< 0.001"
  defp p_value(p), do: :erlang.float_to_binary(Float.round(p * 1.0, 3), decimals: 3)

  defp significance_sentence(nil), do: gettext("Not enough data for a test.")

  defp significance_sentence(p) when p < 0.05 do
    gettext(
      "A difference this large would be unlikely if the groups really answered the same way."
    )
  end

  defp significance_sentence(_p) do
    gettext(
      "This difference is within what chance alone would produce, so it is not evidence of a real one."
    )
  end

  defp test_name(%{t: _t}), do: gettext("t test (Welch)")
  defp test_name(%{f: _f}), do: gettext("One-way ANOVA")
  defp test_name(%{u: _u}), do: gettext("Mann-Whitney U")
  defp test_name(%{h: _h}), do: gettext("Kruskal-Wallis H")
  defp test_name(%{chi_square: _c}), do: gettext("Chi-square test")
  defp test_name(_result), do: gettext("Test")

  defp test_statistic(%{t: t, df: df}), do: "t(#{number(df)}) = #{number(t)}"

  defp test_statistic(%{f: f, df_between: between, df_within: within}),
    do: "F(#{between}, #{within}) = #{number_or_inf(f)}"

  defp test_statistic(%{u: u, z: z}), do: "U = #{number(u)}, z = #{number(z)}"
  defp test_statistic(%{h: h, df: df}), do: "H(#{df}) = #{number(h)}"
  defp test_statistic(%{chi_square: c, df: df}), do: "chi2(#{df}) = #{number(c)}"
  defp test_statistic(_result), do: ""

  defp number_or_inf(:infinity), do: "∞"
  defp number_or_inf(value), do: number(value)

  defp effect_kind({:ok, %{cohens_d: _d}}), do: :cohens_d
  defp effect_kind({:ok, %{eta_squared: _e}}), do: :eta_squared
  defp effect_kind(_test), do: nil

  defp effect_value(result, :cohens_d), do: Map.get(result, :cohens_d)
  defp effect_value(result, :eta_squared), do: Map.get(result, :eta_squared)
  defp effect_value(result, :cramers_v), do: Map.get(result, :cramers_v)

  defp effect_sentence(kind, value) do
    band = Stats.effect_band(kind, value)

    gettext("Effect size %{value} (%{band}).", value: number(value), band: band_label(band))
  end

  defp band_label(:negligible), do: gettext("negligible")
  defp band_label(:small), do: gettext("small")
  defp band_label(:medium), do: gettext("medium")
  defp band_label(:large), do: gettext("large")
  defp band_label(nil), do: gettext("unknown")

  defp coefficient({:ok, result}, key), do: number(Map.fetch!(result, key))
  defp coefficient({:error, :no_variance}, _key), do: gettext("no spread")
  defp coefficient({:error, _reason}, _key), do: "–"

  # `Results` resolves the names once per comparison; looking them up here
  # would be one query per row inside a render.
  defp group_label(nil), do: gettext("Self-paced")
  defp group_label(name) when is_binary(name), do: name

  defp group_rows(comparison) do
    Enum.map(comparison.groups, fn group ->
      %{
        label: group_label(group.name),
        mean: group.descriptives.mean,
        se: group.descriptives.se
      }
    end)
  end

  defp drags_down?(%{alpha_if_deleted: without}, alpha)
       when is_number(without) and is_number(alpha),
       do: without > alpha

  defp drags_down?(_item, _alpha), do: false

  defp crosstabbable?(nil), do: false

  defp crosstabbable?(question),
    do: question.type in [:single_choice, :dichotomous, :scale, :nps]

  defp crosstab_candidates(questions, focus) do
    Enum.filter(questions, &(&1.id != focus.id and crosstabbable?(&1)))
  end

  defp crosstab_error({:error, :not_crosstabbable}) do
    gettext(
      "That question cannot be cross-tabulated: a respondent who picked several answers belongs in more than one row at once."
    )
  end

  defp crosstab_error({:error, _reason}) do
    gettext("Not enough people answered both questions yet.")
  end

  defp comparison_error({:error, :insufficient_groups}) do
    gettext("Only one group has answered so far, so there is nothing to compare.")
  end

  defp comparison_error({:error, _reason}) do
    gettext("This question's answers cannot be compared across groups.")
  end

  defp test_error({:error, :insufficient_data}), do: gettext("Not enough answers for a test yet.")

  defp test_error({:error, :no_variance}) do
    gettext("Everyone answered the same, so there is nothing for a test to find.")
  end

  defp test_error({:error, _reason}), do: gettext("No test applies here.")

  defp type_label(:single_choice), do: gettext("Single choice")
  defp type_label(:multiple_choice), do: gettext("Multiple choice")
  defp type_label(:dichotomous), do: gettext("Yes / no")
  defp type_label(:open_text), do: gettext("Open text")
  defp type_label(:numeric), do: gettext("Number")
  defp type_label(:scale), do: gettext("Scale")
  defp type_label(:multi_scale), do: gettext("Scale matrix")
  defp type_label(:matching), do: gettext("Matching")
  defp type_label(:ranking), do: gettext("Ranking")
  defp type_label(:nps), do: gettext("Recommendation (NPS)")

  defp measurement_label(type) do
    case QuestionTypes.measurement(type) do
      :nominal -> gettext("categories")
      :ordinal -> gettext("an ordering")
      :interval -> gettext("a scale")
      :ratio -> gettext("a count")
      :text -> gettext("free text")
    end
  end

  # -- loading --------------------------------------------------------------

  defp load_results(socket) do
    survey = socket.assigns.survey
    questions = Surveys.list_questions(survey.id)
    opts = scope(socket)

    socket
    |> assign(
      loaded?: true,
      questions: questions,
      cohorts: cohort_options(survey.id),
      summary: Surveys.results_summary(survey.id),
      funnel: Surveys.completion_funnel(survey.id),
      correlations: Surveys.correlations(survey.id, opts),
      crosstab: nil,
      crosstab_with: nil
    )
    |> load_focus(questions, opts)
  end

  defp load_focus(socket, questions, opts) do
    focus =
      Enum.find(questions, &(&1.id == socket.assigns.focus_id)) ||
        List.first(questions)

    if focus do
      assign(socket,
        focus: focus,
        frequencies: Surveys.frequencies(focus, opts),
        descriptives: Surveys.question_descriptives(focus, opts),
        nps: Surveys.nps_bands(focus, opts),
        matrix: Surveys.matrix_counts(focus, opts),
        reliability: Surveys.reliability(focus, opts),
        comparison: Surveys.compare_groups(focus, opts),
        verbatims: Surveys.verbatims(focus, opts)
      )
    else
      assign(socket,
        focus: nil,
        frequencies: nil,
        descriptives: nil,
        nps: nil,
        matrix: nil,
        reliability: nil,
        comparison: nil,
        verbatims: nil
      )
    end
  end

  defp focus_question(socket), do: socket.assigns[:focus]

  defp scope(socket) do
    case socket.assigns.cohort_id do
      nil -> []
      cohort_id -> [cohort_id: cohort_id]
    end
  end

  # Only the cohorts that actually answered: offering a filter that yields
  # nothing is worse than not offering it.
  defp cohort_options(survey_id) do
    survey_id
    |> Surveys.list_responses()
    |> Enum.map(& &1.cohort_id)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Learning.get_cohorts_map()
    |> Enum.map(fn {id, cohort} -> {cohort.name, id} end)
    |> Enum.sort()
  end

  # The download follows whatever cohort filter is on screen, so what someone
  # gets in the file is what they were looking at.
  defp export_path(survey, cohort_id, shape) do
    query = if cohort_id, do: "?" <> URI.encode_query(%{"cohort_id" => cohort_id}), else: ""

    case shape do
      :wide -> ~p"/studio/surveys/#{survey.id}/export.csv" <> query
      :long -> ~p"/studio/surveys/#{survey.id}/export.long.csv" <> query
    end
  end

  defp results_path(socket, overrides) do
    params =
      %{
        "tab" => socket.assigns.tab,
        "cohort_id" => socket.assigns.cohort_id,
        "question_id" => socket.assigns.focus_id
      }
      |> Map.merge(overrides)
      |> Enum.reject(fn {_key, value} -> value in [nil, "", "overview"] end)
      |> Map.new()

    ~p"/studio/surveys/#{socket.assigns.survey.id}/results?#{params}"
  end
end
