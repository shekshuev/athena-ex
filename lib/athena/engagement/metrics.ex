defmodule Athena.Engagement.Metrics do
  @moduledoc """
  The engagement metric catalog: per-block numbers a teacher or researcher
  can actually read, and the course-wide aggregates the dashboards are built
  from.

  Every metric is *defined* in `Athena.Engagement.Accumulator`: events are
  folded into additive per-(student, block, day) counters, and metrics are
  derived from those. Course-wide aggregates (`student_radar/3`,
  `cohort_flag_profile/3`, `course_overview/3`, ...) read past days from the
  pre-aggregated `Athena.Engagement.Rollups` and only today from raw events,
  falling back to raw events for the whole window while rollups aren't
  ready (`Athena.Engagement.Rollups.ready?/0`). Pass `source: :raw` to force
  the raw path. Both paths produce identical numbers.

  Course-wide windows are whole app-timezone days: `since` is rounded down
  to the start of its day, so "last 7 days" means the same thing whether it
  is read from rollups or from raw events.

  `get_metrics/1`, `funnel/2`, `time_series/3` (single block or section,
  cheap) always read raw events.
  """

  alias Athena.Content
  alias Athena.TimeZones
  alias Athena.Content.Policy
  alias Athena.Content.Block

  alias Athena.Engagement.{
    Accumulator,
    CourseMap,
    DashboardCache,
    Events,
    Rollups,
    StudentAssessment,
    TheoryLinks
  }

  alias Athena.Learning

  @doc """
  Metrics for a course-tree node, optionally narrowed to one cohort and/or
  one student, and optionally to only events at or after `:since` - the
  shape a future "pick a node, filter above it" dashboard needs (and what
  `student_radar/3` uses to window its indices). `resource_type: :block`
  returns one metrics map; `:section` returns `%{block_id => metrics}` for
  every block directly inside it.
  """
  @spec get_metrics(%{
          required(:resource_type) => :block | :section,
          required(:resource_id) => binary(),
          optional(:cohort_id) => binary() | nil,
          optional(:account_id) => binary() | nil,
          optional(:since) => DateTime.t() | nil
        }) :: map()
  def get_metrics(%{resource_type: :block, resource_id: block_id} = scope) do
    with {:ok, block} <- Content.get_block(block_id),
         {:ok, section} <- Content.get_section(block.section_id) do
      section_blocks = Content.list_blocks_by_section(section.id, :all)
      accumulators = section_accumulators(section_blocks, scope)
      block_metrics(block, section, accumulators, scope)
    else
      _ -> %{}
    end
  end

  def get_metrics(%{resource_type: :section, resource_id: section_id} = scope) do
    case Content.get_section(section_id) do
      {:ok, section} ->
        section_blocks = Content.list_blocks_by_section(section_id, :all)
        accumulators = section_accumulators(section_blocks, scope)

        Map.new(section_blocks, fn block ->
          {block.id, block_metrics(block, section, accumulators, scope)}
        end)

      _ ->
        %{}
    end
  end

  # `%{{account_id, block_id} => accumulator}` for one section's blocks.
  defp section_accumulators(section_blocks, scope) do
    section_blocks
    |> Enum.map(& &1.id)
    |> Events.list_events_for_scope(Map.get(scope, :cohort_id), Map.get(scope, :since))
    |> filter_by_account(Map.get(scope, :account_id))
    |> Accumulator.build(positions(section_blocks))
    |> Accumulator.by_account_block()
  end

  defp block_metrics(block, section, accumulators, scope) do
    rule = Policy.resolve_engagement_rule(block, section)

    case Map.get(scope, :account_id) do
      nil ->
        accumulators
        |> Enum.filter(fn {{_account_id, block_id}, _acc} -> block_id == block.id end)
        |> Enum.map(&elem(&1, 1))
        |> Accumulator.to_cohort_metrics(block.type, rule)

      account_id ->
        accumulators
        |> Map.get({account_id, block.id}, Accumulator.empty())
        |> Accumulator.to_metrics(block.type, rule)
    end
  end

  defp positions(blocks), do: Map.new(blocks, &{&1.id, {&1.section_id, &1.order}})

  @doc """
  Funnel (drop-off) for one block: how many distinct students reached each
  stage - opened it at all, then actually interacted with it. Answering/
  submitting stages need `Athena.Learning.Submission` joined in and are left
  for a follow-up (see moduledoc).
  """
  @spec funnel(binary(), binary() | nil) :: [%{stage: String.t(), accounts: non_neg_integer()}]
  def funnel(block_id, cohort_id \\ nil) do
    events = Events.list_events_for_scope([block_id], cohort_id)

    opened = distinct_accounts(events, &(&1.event_type == :viewport_enter))

    interacted =
      distinct_accounts(
        events,
        &(&1.event_type in [
            :viewport_exit,
            :paste_detected,
            :video_play,
            :attachment_open,
            :image_zoom
          ])
      )

    [
      %{stage: "opened", accounts: MapSet.size(opened)},
      %{stage: "interacted", accounts: opened |> MapSet.intersection(interacted) |> MapSet.size()}
    ]
  end

  @doc """
  Pearson correlation coefficient between two per-account measurements
  (e.g. dwell seconds on one block vs. a score fetched separately) - kept
  generic on purpose so it doesn't need to know where either measurement
  came from. `nil` if fewer than 2 accounts appear in both maps, or either
  side has zero variance.
  """
  @spec correlate(%{binary() => number()}, %{binary() => number()}) :: float() | nil
  def correlate(measurements_a, measurements_b) do
    shared_accounts =
      measurements_a
      |> Map.keys()
      |> MapSet.new()
      |> MapSet.intersection(MapSet.new(Map.keys(measurements_b)))

    pairs =
      Enum.map(shared_accounts, &{Map.fetch!(measurements_a, &1), Map.fetch!(measurements_b, &1)})

    pearson(pairs)
  end

  @doc """
  A metric tracked week over week for one block - the "is engagement
  trending up or down, is the nudge rate falling off over the semester"
  view. `metric` is one of `:avg_dwell_seconds`, `:sample_size`,
  `:nudge_shown_count`.
  """
  @spec time_series(binary(), binary() | nil, atom()) :: [
          %{week: Date.t(), value: number() | nil}
        ]
  def time_series(block_id, cohort_id, metric) do
    [block_id]
    |> Events.list_events_for_scope(cohort_id)
    |> Enum.group_by(&week_start/1)
    |> Enum.map(fn {week, week_events} ->
      %{week: week, value: time_series_value(metric, week_events)}
    end)
    |> Enum.sort_by(& &1.week, Date)
  end

  @doc """
  A flat "one row = one student × one block" table across every block in a
  course, for every student in the given cohorts - the shape a statistics
  package (R/Python/SPSS) wants: every metric as its own column, plus
  `cohort_id` so groups can be compared. Whole history, one scope pass per
  cohort.
  """
  @spec export_wide_table(binary(), [binary()]) :: [map()]
  def export_wide_table(course_id, cohort_ids) do
    indexes = Map.new(cohort_ids, &{&1, build_scope_index(course_id, &1, nil)})
    students = Map.new(cohort_ids, &{&1, students_in_cohort(&1)})
    blocks = cohort_ids |> List.first() |> then(&(&1 && indexes[&1].all_blocks)) || []

    for block <- blocks,
        cohort_id <- cohort_ids,
        account_id <- Map.fetch!(students, cohort_id) do
      index = Map.fetch!(indexes, cohort_id)

      index.acc_by_account_block
      |> Map.get({account_id, block.id}, Accumulator.empty())
      |> Accumulator.to_metrics(block.type, Map.fetch!(index.resolved_rule_by_block_id, block.id))
      |> Map.merge(%{
        cohort_id: cohort_id,
        account_id: account_id,
        block_id: block.id,
        block_type: block.type
      })
    end
  end

  defp flatten_sections(sections) do
    Enum.flat_map(sections, fn section -> [section | flatten_sections(section.children)] end)
  end

  defp students_in_cohort(cohort_id) do
    case Learning.list_cohort_memberships(cohort_id, %{limit: 1000}) do
      {:ok, {memberships, _meta}} -> Enum.map(memberships, & &1.account_id)
      _ -> []
    end
  end

  # The shared foundation for every course-wide aggregate below: the
  # course's structure (a fixed handful of queries) plus every student's
  # accumulated activity per block over the window, read from rollups for
  # past days and from raw events for today (or from raw events only, see
  # the moduledoc). Nothing downstream touches the database per (block,
  # student) pair.
  defp build_scope_index(course_id, cohort_id, since, opts \\ []) do
    sections = course_id |> Content.get_course_tree(:all) |> flatten_sections()
    section_by_id = Map.new(sections, &{&1.id, &1})

    blocks_by_section =
      sections
      |> Enum.map(& &1.id)
      |> Content.list_blocks_by_section_ids()
      |> Enum.group_by(& &1.section_id)
      |> Map.new(fn {section_id, blocks} -> {section_id, Enum.sort_by(blocks, & &1.order)} end)

    all_blocks = Enum.flat_map(sections, &Map.get(blocks_by_section, &1.id, []))
    from_day = since && since |> TimeZones.to_app_zone() |> DateTime.to_date()

    resolved_rule_by_block_id =
      Map.new(all_blocks, fn block ->
        section = Map.fetch!(section_by_id, block.section_id)
        {block.id, Policy.resolve_engagement_rule(block, section)}
      end)

    %{
      sections: sections,
      section_by_id: section_by_id,
      blocks_by_section: blocks_by_section,
      all_blocks: all_blocks,
      resolved_rule_by_block_id: resolved_rule_by_block_id,
      cohort_id: cohort_id,
      from_day: from_day
    }
    |> Map.merge(load_activity(cohort_id, all_blocks, from_day, Keyword.get(opts, :source)))
    |> then(&Map.put(&1, :baselines, group_baselines(&1.acc_by_account_block)))
  end

  # Per block, what "normal" looks like in this cohort over the window:
  # the median of students' average time on it, and the 80th percentile of
  # their answer changes - each only once `min_group_for_baseline`
  # students have data, so two students never define "the group".
  defp group_baselines(acc_by_account_block) do
    min_peers = Keyword.get(engagement_config(), :min_group_for_baseline, 5)
    percentile = Keyword.get(engagement_config(), :hesitation_group_percentile, 0.8)

    acc_by_account_block
    |> Enum.group_by(fn {{_account_id, block_id}, _acc} -> block_id end, &elem(&1, 1))
    |> Map.new(fn {block_id, accs} ->
      dwells = for %{dwell_n: n, dwell_sum: sum} <- accs, n > 0, do: sum / n

      changes =
        for %{event_count: events, answer_changed: changed} <- accs, events > 0, do: changed

      {block_id,
       %{
         peers: length(accs),
         dwell_median: if(length(dwells) >= min_peers, do: percentile(dwells, 0.5)),
         answer_changes_p80: if(length(changes) >= min_peers, do: percentile(changes, percentile))
       }}
    end)
  end

  defp percentile(values, p) do
    sorted = Enum.sort(values)
    Enum.at(sorted, min(round(p * (length(sorted) - 1)), length(sorted) - 1))
  end

  defp load_activity(_cohort_id, _blocks, _from_day, :structure_only),
    do: %{acc_by_account_block: %{}, active_by_day: %{}, hour_matrix: %{}}

  defp load_activity(cohort_id, blocks, from_day, source) do
    if cohort_id && source != :raw && Rollups.ready?() do
      hybrid_activity(cohort_id, blocks, from_day)
    else
      blocks
      |> Enum.map(& &1.id)
      |> Events.list_events_for_scope(cohort_id, from_day && TimeZones.start_of_day(from_day))
      |> Accumulator.build(positions(blocks))
      |> activity_from_buckets()
    end
  end

  # Past days from rollups + today from raw events. Today is never read
  # from rollups, so the two never overlap.
  defp hybrid_activity(cohort_id, blocks, from_day) do
    block_ids = Enum.map(blocks, & &1.id)
    today = TimeZones.today()

    past =
      if from_day && Date.compare(from_day, today) != :lt do
        %{acc_by_account_block: %{}, active_by_day: %{}, hour_matrix: %{}}
      else
        yesterday = Date.add(today, -1)

        %{
          acc_by_account_block:
            Rollups.account_block_totals(cohort_id, block_ids, from_day, yesterday),
          active_by_day:
            Rollups.active_students_by_day(cohort_id, block_ids, from_day, yesterday),
          hour_matrix: Rollups.hour_matrix(cohort_id, block_ids, from_day, yesterday)
        }
      end

    current =
      block_ids
      |> Events.list_events_for_scope(cohort_id, TimeZones.start_of_day(today))
      |> Accumulator.build(positions(blocks))
      |> activity_from_buckets()

    %{
      acc_by_account_block:
        Map.merge(past.acc_by_account_block, current.acc_by_account_block, fn _key, a, b ->
          Accumulator.merge(a, b)
        end),
      active_by_day: Map.merge(past.active_by_day, current.active_by_day),
      hour_matrix: Map.merge(past.hour_matrix, current.hour_matrix, fn _key, a, b -> a + b end)
    }
  end

  defp activity_from_buckets(buckets) do
    active_by_day =
      buckets
      |> Enum.filter(fn {_key, acc} -> acc.event_count > 0 end)
      |> Enum.group_by(fn {{_account, _block, day}, _acc} -> day end, fn {{account, _, _}, _} ->
        account
      end)
      |> Map.new(fn {day, accounts} -> {day, accounts |> Enum.uniq() |> length()} end)

    hour_matrix =
      Enum.reduce(buckets, %{}, fn {{_account, _block, day}, acc}, matrix ->
        dow = Date.day_of_week(day)

        acc.hour_counts
        |> Enum.with_index()
        |> Enum.reduce(matrix, fn
          {0, _hour}, m -> m
          {count, hour}, m -> Map.update(m, {dow, hour}, count, &(&1 + count))
        end)
      end)

    %{
      acc_by_account_block: Accumulator.by_account_block(buckets),
      active_by_day: active_by_day,
      hour_matrix: hour_matrix
    }
  end

  @doc """
  The "Group Radar" screen's data: for every student in `cohort_id`, how
  many `flag_concerns/1` slacking/struggling flags fired across the course
  (or, with `opts[:section_id]`, just one section/lesson), and a
  color-coded `status` derived from *counting* them - never a hidden weighted
  score, so a teacher can always see exactly which blocks and which flags
  produced a given number (`flagged_blocks`).

  Always windowed by `opts[:since]` (default: the last
  `student_radar_default_window_days` config, currently 7) rather than a
  lifetime total - a student is a process, not a permanent label: the
  point of comparing the experiment's three cohorts is to see whether
  behavior *changes* after a teacher steps in, which a cumulative-forever
  score could never show. `progress_percent` is the one field that stays a
  whole-course fact regardless of the window, since it isn't a behavior.
  """
  @spec student_radar(binary(), binary(), keyword()) :: [map()]
  def student_radar(cohort_id, course_id, opts \\ []) do
    cached(:student_radar, cohort_id, course_id, opts, fn ->
      do_student_radar(cohort_id, course_id, opts)
    end)
  end

  defp do_student_radar(cohort_id, course_id, opts) do
    since = Keyword.get(opts, :since, default_since())

    course_id
    |> build_scope_index(cohort_id, since, opts)
    |> radar_from_index(cohort_id, course_id, opts)
  end

  @doc """
  What the gradebook's engagement layer draws on top of the scores, over
  the whole course: every student's radar `level`, which theory blocks each
  graded task builds on (`theory_by_task`, see
  `Athena.Engagement.TheoryLinks`), how each student went through each of
  those theory blocks (`reviews`, `%{{account_id, block_id} => review}`,
  `status` `:ok`/`:superficial`/`:skipped`), and every section's content
  (non-graded) blocks in course order (`content_blocks`) for theory columns.
  """
  @spec gradebook_engagement(binary(), binary(), keyword()) :: map()
  def gradebook_engagement(cohort_id, course_id, opts \\ []) do
    opts = Keyword.put(opts, :since, nil)

    cached(:gradebook_engagement, cohort_id, course_id, opts, fn ->
      index = build_scope_index(course_id, cohort_id, nil, opts)
      rows = radar_from_index(index, cohort_id, course_id, opts)
      gradable = Enum.filter(index.all_blocks, &Block.gradable?/1)

      theory_by_task =
        Map.new(gradable, fn block ->
          theory = TheoryLinks.theory_blocks_for(block, index.sections, index.blocks_by_section)
          {block.id, Enum.map(theory, & &1.id)}
        end)

      theory_ids = theory_by_task |> Map.values() |> List.flatten() |> MapSet.new()
      theory_blocks = Enum.filter(index.all_blocks, &MapSet.member?(theory_ids, &1.id))

      reviews =
        for %{account_id: account_id} <- rows, block <- theory_blocks, into: %{} do
          {{account_id, block.id}, theory_review(block, account_id, index, index)}
        end

      %{
        levels: Map.new(rows, &{&1.account_id, &1.level}),
        theory_by_task: theory_by_task,
        reviews: reviews,
        content_blocks:
          Map.new(index.blocks_by_section, fn {section_id, blocks} ->
            {section_id, Enum.reject(blocks, &Block.gradable?/1)}
          end)
      }
    end)
  end

  @doc """
  The Course Map: for every block of the course, in course order, how the
  cohort did on it over the window - who opened it, who completed it, how
  long they spent, how many rushed through it or got stuck, how they
  scored - and which of that makes it a problem spot
  (`Athena.Engagement.CourseMap`). With `account_id:` every block also
  carries that one student's own numbers and signals next to the cohort's.

  Behaviour is windowed by `:since`; completion and scores are whole-course
  facts. Returns `%{sections: [%{section, depth, block_ids}], blocks:
  %{block_id => block}, entries: %{block_id => entry}, students_count}`.
  """
  @spec course_map(binary(), binary(), keyword()) :: map()
  def course_map(cohort_id, course_id, opts \\ []) do
    account_id = Keyword.get(opts, :account_id)

    cached({:course_map, account_id}, cohort_id, course_id, opts, fn ->
      since = Keyword.get(opts, :since, default_since())
      index = build_scope_index(course_id, cohort_id, since, opts)
      students = students_in_cohort(cohort_id)
      block_ids = Enum.map(index.all_blocks, & &1.id)

      context = %{
        index: index,
        students: students,
        completed:
          Learning.completed_block_ids_by_account(students, block_ids, team_scope_id(cohort_id)),
        cells: cohort_cells(cohort_id, course_id, students),
        account_id: account_id,
        config: engagement_config()
      }

      %{
        sections:
          Enum.map(index.sections, fn section ->
            %{
              section: section,
              depth: section_depth(section),
              block_ids: index.blocks_by_section |> Map.get(section.id, []) |> Enum.map(& &1.id)
            }
          end),
        blocks: Map.new(index.all_blocks, &{&1.id, &1}),
        entries: Map.new(index.all_blocks, &{&1.id, map_entry(&1, context)}),
        students_count: length(students)
      }
    end)
  end

  defp section_depth(%{path: %{labels: labels}}) when is_list(labels),
    do: max(length(labels) - 1, 0)

  defp section_depth(_section), do: 0

  defp map_entry(block, context) do
    stats = block_cohort_stats(block, context)
    issues = CourseMap.cohort_issues(stats, context.config)

    entry = %{stats: stats, issues: issues, severity: CourseMap.severity(issues)}

    case context.account_id do
      nil ->
        entry

      account_id ->
        Map.put(entry, :student, block_student_view(block, account_id, stats, context))
    end
  end

  defp block_cohort_stats(block, context) do
    %{index: index, students: students} = context

    accs =
      for account_id <- students,
          acc = Map.get(index.acc_by_account_block, {account_id, block.id}),
          acc != nil and acc.event_count > 0,
          do: {account_id, acc}

    flags =
      Enum.map(accs, fn {account_id, _acc} -> student_block_flags(block, account_id, index) end)

    cohort_metrics =
      accs
      |> Enum.map(&elem(&1, 1))
      |> Accumulator.to_cohort_metrics(
        block.type,
        Map.fetch!(index.resolved_rule_by_block_id, block.id)
      )

    cells =
      for account_id <- students,
          cell = Map.get(context.cells, {account_id, block.id}),
          cell != nil,
          do: cell

    scores = for %{state: :scored, score: score} <- cells, do: score
    pass_mark = Keyword.get(context.config, :low_score_threshold, 50)

    %{
      students: length(students),
      opened: length(accs),
      completed:
        Enum.count(
          students,
          &MapSet.member?(Map.get(context.completed, &1, MapSet.new()), block.id)
        ),
      avg_dwell: cohort_metrics[:avg_dwell_seconds],
      dwell_median: get_in(index.baselines, [block.id, :dwell_median]),
      avg_scroll: cohort_metrics[:avg_scroll_depth_percent],
      skip_ratio: cohort_metrics[:skip_ratio],
      skimmed: Enum.count(flags, &(&1.slacking_flags != [])),
      stuck: Enum.count(flags, &(&1.struggling_flags != [])),
      backtrack_rate: cohort_metrics[:backtrack_rate],
      hesitation_rate: cohort_metrics[:hesitation_rate],
      content_flags: flag_concerns(cohort_metrics).content,
      scored: length(scores),
      passed: Enum.count(scores, &(&1 >= pass_mark)),
      score_avg: average(scores),
      attempted: length(cells),
      attempts_avg: cells |> Enum.map(& &1.attempts) |> average()
    }
  end

  defp block_student_view(block, account_id, stats, context) do
    %{index: index, config: config} = context
    acc = Map.get(index.acc_by_account_block, {account_id, block.id})
    metrics = if acc, do: student_block_metrics(block, acc, index), else: %{}
    flagged = student_block_flags(block, account_id, index)
    cell = Map.get(context.cells, {account_id, block.id})

    signals = flag_signals(flagged) ++ score_signals(cell, stats, config)

    %{
      opened?: acc != nil and acc.event_count > 0,
      completed?: MapSet.member?(Map.get(context.completed, account_id, MapSet.new()), block.id),
      avg_dwell: metrics[:avg_dwell_seconds],
      avg_scroll: metrics[:avg_scroll_depth_percent],
      skip_ratio: metrics[:skip_ratio],
      cell: cell,
      signals: signals,
      severity: CourseMap.student_severity(signals)
    }
  end

  defp flag_signals(flagged) do
    for {category, flags} <- [
          slacking: flagged.slacking_flags,
          struggling: flagged.struggling_flags,
          integrity: flagged.integrity_flags
        ],
        flag <- flags do
      flagged.details
      |> Map.get(flag, %{basis: :pattern})
      |> Map.merge(%{key: flag, category: category, block_id: flagged.block_id})
    end
  end

  # The same rules as the Group Radar's performance signals, against this
  # block's cohort numbers.
  defp score_signals(nil, _stats, _config), do: []

  defp score_signals(cell, stats, config) do
    pass_mark = Keyword.get(config, :low_score_threshold, 50)
    min_attempts = Keyword.get(config, :many_attempts_min, 3)

    low =
      if cell.state == :scored and cell.score < pass_mark,
        do: [
          %{
            key: :low_score,
            category: :performance,
            value: cell.score,
            baseline: stats.score_avg,
            basis: :absolute,
            threshold: pass_mark,
            peers: stats.scored
          }
        ],
        else: []

    many =
      if cell.attempts >= min_attempts and
           (is_nil(stats.attempts_avg) or cell.attempts >= 2 * stats.attempts_avg),
         do: [
           %{
             key: :many_attempts,
             category: :performance,
             value: cell.attempts,
             baseline: stats.attempts_avg,
             basis: :group,
             peers: stats.attempted
           }
         ],
         else: []

    low ++ many
  end

  defp average([]), do: nil
  defp average(values), do: Enum.sum(values) / length(values)

  @doc """
  One cohort's numbers for the cross-cohort comparison, as additive sums and
  counts (never pre-averaged), so several cohorts can be combined into a
  fair "course average" by adding them up:

    * `students`, `progress_sum` (sum of progress percents), `levels`
      (`%{level => students}` from the Group Radar);
    * `slacking_students` / `struggling_students` - students with enough
      rushing / getting-stuck signals to count for that level's rule;
      `integrity_students` - with any exam-integrity signal;
    * `scored`, `score_sum`, `attempted`, `first_try` (passed on the first
      attempt), `flagged_attempts` (cheating monitor: high risk or a
      confirmed violation) - whole course;
    * `sections` - `%{section_id => %{scored, score_sum, done, total}}`,
      per-section scores and completion (`done` of `total` student × block
      pairs).

  Behaviour is windowed by `:since`, like the radars.
  """
  @spec cohort_summary(binary(), binary(), keyword()) :: map()
  def cohort_summary(cohort_id, course_id, opts \\ []) do
    cached(:cohort_summary, cohort_id, course_id, opts, fn ->
      since = Keyword.get(opts, :since, default_since())
      index = build_scope_index(course_id, cohort_id, since, opts)
      rows = radar_from_index(index, cohort_id, course_id, opts)
      students = Enum.map(rows, & &1.account_id)
      cells = cohort_cells(cohort_id, course_id, students)
      config = engagement_config()
      pass_mark = Keyword.get(config, :low_score_threshold, 50)

      completed =
        Learning.completed_block_ids_by_account(
          students,
          Enum.map(index.all_blocks, & &1.id),
          team_scope_id(cohort_id)
        )

      gradable = for block <- index.all_blocks, Block.gradable?(block), do: block.id

      student_cells =
        for s <- students, b <- gradable, cell = cells[{s, b}], cell != nil, do: cell

      scores = for %{state: :scored, score: score} <- student_cells, do: score
      in_category = fn row, category -> Enum.count(row.signals, &(&1.category == category)) end

      %{
        students: length(students),
        progress_sum: rows |> Enum.map(& &1.progress_percent) |> Enum.sum(),
        levels: Enum.frequencies_by(rows, & &1.level),
        slacking_students:
          Enum.count(
            rows,
            &(in_category.(&1, :slacking) >=
                Keyword.get(config, :student_radar_slacking_threshold, 2))
          ),
        struggling_students:
          Enum.count(
            rows,
            &(in_category.(&1, :struggling) >=
                Keyword.get(config, :student_radar_struggling_threshold, 2))
          ),
        integrity_students: Enum.count(rows, &(in_category.(&1, :integrity) > 0)),
        scored: length(scores),
        score_sum: Enum.sum(scores),
        attempted: length(student_cells),
        first_try:
          Enum.count(
            student_cells,
            &(&1.attempts == 1 and &1.state == :scored and &1.score >= pass_mark)
          ),
        flagged_attempts: Enum.count(student_cells, &(&1[:integrity] in [:red, :confirmed])),
        sections:
          Map.new(
            index.sections,
            &{&1.id, section_summary(&1, index, students, cells, completed)}
          )
      }
    end)
  end

  defp section_summary(section, index, students, cells, completed) do
    blocks = Map.get(index.blocks_by_section, section.id, [])

    scores =
      for s <- students,
          block <- blocks,
          %{state: :scored, score: score} <- [Map.get(cells, {s, block.id})],
          do: score

    done =
      for s <- students,
          block <- blocks,
          MapSet.member?(Map.get(completed, s, MapSet.new()), block.id),
          reduce: 0,
          do: (count -> count + 1)

    %{
      scored: length(scores),
      score_sum: Enum.sum(scores),
      done: done,
      total: length(students) * length(blocks)
    }
  end

  defp radar_from_index(index, cohort_id, course_id, opts) do
    blocks = radar_blocks(index, Keyword.get(opts, :section_id))
    students = students_in_cohort(cohort_id)

    completed_by_account =
      Learning.completed_block_ids_by_account(
        students,
        Enum.map(blocks, & &1.id),
        team_scope_id(cohort_id)
      )

    rows =
      Enum.map(students, fn account_id ->
        student_radar_row(account_id, Map.fetch!(completed_by_account, account_id), blocks, index)
      end)

    assess_rows(rows, cohort_id, course_id, blocks, completed_by_account, index, opts)
  end

  # Adds `level`, `signals` and `average_score` to every radar row (see
  # `Athena.Engagement.StudentAssessment`).
  defp assess_rows(rows, cohort_id, course_id, blocks, completed_by_account, index, opts) do
    cells = cohort_cells(cohort_id, course_id, Enum.map(rows, & &1.account_id))
    window_start = index.from_day && TimeZones.start_of_day(index.from_day)
    theory = theory_reviewer(cells, blocks, window_start, index, opts)

    assessments =
      StudentAssessment.assess_cohort(%{
        students: Enum.map(rows, & &1.account_id),
        blocks: blocks,
        flagged_blocks: Map.new(rows, &{&1.account_id, &1.flagged_blocks}),
        active:
          for(
            {{account_id, _block_id}, acc} <- index.acc_by_account_block,
            acc.event_count > 0,
            into: MapSet.new(),
            do: account_id
          ),
        cells: cells,
        completed: completed_by_account,
        progress: Map.new(rows, &{&1.account_id, &1.progress_percent}),
        window_start: window_start,
        theory: theory
      })

    gradable_ids = for block <- blocks, Block.gradable?(block), do: block.id

    Enum.map(rows, fn row ->
      scores =
        for block_id <- gradable_ids,
            %{state: :scored, score: score} <- [Map.get(cells, {row.account_id, block_id})],
            do: score

      row
      |> Map.merge(Map.fetch!(assessments, row.account_id))
      |> Map.put(
        :average_score,
        if(scores == [], do: nil, else: Enum.sum(scores) / length(scores))
      )
    end)
  end

  # Best-attempt gradebook cells keyed by student - for a team cohort every
  # member shares the team's own cells.
  defp cohort_cells(cohort_id, course_id, account_ids) do
    case Learning.get_cohorts_map([cohort_id]) do
      %{^cohort_id => cohort} ->
        %{cells: cells} = Learning.build_gradebook(cohort, course_id)

        if cohort.type == :team do
          for {{_team_id, block_id}, cell} <- cells, account_id <- account_ids, into: %{} do
            {{account_id, block_id}, cell}
          end
        else
          cells
        end

      _ ->
        %{}
    end
  end

  # How each student went through the theory in front of a graded task
  # (`Athena.Engagement.TheoryLinks`), over the whole course - the material
  # may well have been read weeks before the test. Only loaded for tasks
  # that could possibly produce a performance signal.
  defp theory_reviewer(cells, blocks, window_start, index, opts) do
    config = engagement_config()

    suspect_score =
      Keyword.get(config, :low_score_threshold, 50) +
        Keyword.get(config, :low_score_group_gap, 30)

    min_attempts = Keyword.get(config, :many_attempts_min, 3)

    suspect_block_ids =
      for {{_account_id, block_id}, cell} <- cells,
          window_start == nil or DateTime.compare(cell.submitted_at, window_start) != :lt,
          (cell.state == :scored and cell.score < suspect_score) or cell.attempts >= min_attempts,
          into: MapSet.new(),
          do: block_id

    theory_by_block =
      for block <- blocks,
          MapSet.member?(suspect_block_ids, block.id),
          into: %{},
          do:
            {block.id,
             TheoryLinks.theory_blocks_for(block, index.sections, index.blocks_by_section)}

    theory_blocks = theory_by_block |> Map.values() |> List.flatten() |> Enum.uniq_by(& &1.id)

    theory_index =
      cond do
        theory_blocks == [] ->
          %{acc_by_account_block: %{}, baselines: %{}}

        index.from_day == nil ->
          index

        true ->
          activity =
            load_activity(index.cohort_id, theory_blocks, nil, Keyword.get(opts, :source))

          Map.put(activity, :baselines, group_baselines(activity.acc_by_account_block))
      end

    fn account_id, block ->
      theory_by_block
      |> Map.get(block.id, [])
      |> Enum.map(&theory_review(&1, account_id, theory_index, index))
    end
  end

  @theory_flags [:fast_dwell, :shallow_scroll, :video_skipped]

  defp theory_review(block, account_id, theory_index, index) do
    case Map.get(theory_index.acc_by_account_block, {account_id, block.id}) do
      acc when acc == nil or acc.event_count == 0 ->
        %{block_id: block.id, block_type: block.type, status: :skipped}

      acc ->
        metrics =
          acc
          |> Accumulator.to_metrics(
            block.type,
            Map.fetch!(index.resolved_rule_by_block_id, block.id)
          )
          |> with_group_baselines(Map.get(theory_index.baselines, block.id))

        flags = Enum.filter(flag_concerns(metrics).slacking, &(&1 in @theory_flags))

        %{
          block_id: block.id,
          block_type: block.type,
          status: if(flags == [], do: :ok, else: :superficial),
          flags: Map.new(flags, &{&1, flag_detail(&1, metrics)})
        }
    end
  end

  # The full set of student-level flags from `slacking_flags/2` +
  # `struggling_flags/2` - kept as an explicit, ordered list (rather than
  # derived at runtime) so a radar chart's axes stay in the same order for
  # every cohort it plots, and so this list is the one place to update if
  # `flag_concerns/1`'s rules ever gain or lose a named flag.
  @radar_axes [
    :fast_dwell,
    :shallow_scroll,
    :heavy_paste,
    :video_skipped,
    :no_debug_cycle,
    :slow_dwell,
    :hesitation,
    :backtracked,
    :panic_debugging,
    :printscreen_attempted,
    :copy_attempted,
    :cut_attempted,
    :multi_tab_detected,
    :excessive_tab_switching,
    :heavy_paste_on_exam
  ]

  @doc """
  The flag names `cohort_flag_profile/3` reports a rate for, in a stable
  order - the single source of truth for a radar chart's axes, so the UI
  never needs its own copy of this list to keep in sync.
  """
  @spec radar_axes() :: [atom()]
  def radar_axes, do: @radar_axes

  @doc """
  The cohort-wide "profile" a Radar Chart plots to compare cohorts: for
  each of the `@radar_axes` flags, what fraction of every student × block
  pair in scope fired it - `0.0` to `1.0` per axis, `0.0` (not a crash)
  when there is nothing to observe yet. Folds the exact same
  `student_block_flags/3` grid `student_radar/3` already builds, just
  tallied by flag name instead of by student, so a cohort's radar profile
  and its "Student Radar" table can never silently disagree about what
  counts as a flag firing.
  """
  @spec cohort_flag_profile(binary(), binary(), keyword()) :: %{atom() => float()}
  def cohort_flag_profile(cohort_id, course_id, opts \\ []) do
    cached(:cohort_flag_profile, cohort_id, course_id, opts, fn ->
      do_cohort_flag_profile(cohort_id, course_id, opts)
    end)
  end

  defp do_cohort_flag_profile(cohort_id, course_id, opts) do
    since = Keyword.get(opts, :since, default_since())
    index = build_scope_index(course_id, cohort_id, since, opts)
    blocks = radar_blocks(index, Keyword.get(opts, :section_id))
    students = students_in_cohort(cohort_id)
    total_observations = length(blocks) * length(students)

    if total_observations == 0 do
      Map.new(@radar_axes, &{&1, 0.0})
    else
      counts =
        for block <- blocks, account_id <- students, reduce: %{} do
          acc -> tally_block_account_flags(block, account_id, index, acc)
        end

      Map.new(@radar_axes, fn axis -> {axis, Map.get(counts, axis, 0) / total_observations} end)
    end
  end

  defp tally_block_account_flags(block, account_id, index, acc) do
    flags = student_block_flags(block, account_id, index)
    Enum.reduce(flags.flags, acc, fn flag, acc2 -> Map.update(acc2, flag, 1, &(&1 + 1)) end)
  end

  @doc """
  The "Course Radar" screen's per-section stacked-bar data: for every
  section of `course_id`, how many slacking (red) and struggling (yellow)
  flags fired across every block in that section, summed over the whole
  cohort - a tall red bar on one section means "most students are gaming
  this section", a tall yellow bar means "most students are stuck here",
  either way it is the section to look at first. Sections are always the
  full course, in course order.
  """
  @spec section_flag_totals(binary(), binary(), keyword()) :: [
          %{
            section_id: binary(),
            section_title: String.t(),
            slacking_count: non_neg_integer(),
            struggling_count: non_neg_integer(),
            integrity_count: non_neg_integer()
          }
        ]
  def section_flag_totals(cohort_id, course_id, opts \\ []) do
    since = Keyword.get(opts, :since, default_since())
    index = build_scope_index(course_id, cohort_id, since, opts)
    section_flag_totals_from_index(index, students_in_cohort(cohort_id))
  end

  defp section_flag_totals_from_index(index, students) do
    Enum.map(index.sections, fn section -> section_flag_total(section, students, index) end)
  end

  @doc """
  Every course-wide "Course Radar" dataset in one pass - `section_flag_totals/3`,
  `activity_heatmap/3`, `course_funnel/3`, `active_students_trend/3` and
  `nudge_correction_rate/3` all computed off a single scope index instead of
  each loading the same activity again.

  `include_nudges: false` leaves out `nudge_correction_rate` - the one
  dataset that needs exact event times and so can't be read from rollups;
  a screen can load it separately so it never holds up the rest.
  """
  @spec course_overview(binary(), binary(), keyword()) :: %{
          section_flag_totals: list(),
          activity_heatmap: list(),
          course_funnel: list(),
          active_students_trend: list(),
          nudge_correction_rate: list()
        }
  def course_overview(cohort_id, course_id, opts \\ []) do
    cached(:course_overview, cohort_id, course_id, opts, fn ->
      do_course_overview(cohort_id, course_id, opts)
    end)
  end

  defp do_course_overview(cohort_id, course_id, opts) do
    since = Keyword.get(opts, :since, default_since())
    index = build_scope_index(course_id, cohort_id, since, opts)
    students = students_in_cohort(cohort_id)

    overview = %{
      section_flag_totals: section_flag_totals_from_index(index, students),
      activity_heatmap: heatmap_cells(index.hour_matrix),
      course_funnel: course_funnel_from_index(index, cohort_id),
      active_students_trend: trend_points(index.active_by_day)
    }

    if Keyword.get(opts, :include_nudges, true),
      do: Map.put(overview, :nudge_correction_rate, nudge_correction_rate_from_index(index)),
      else: overview
  end

  defp section_flag_total(section, students, index) do
    blocks = Map.get(index.blocks_by_section, section.id, [])

    {slacking_count, struggling_count, integrity_count} =
      for block <- blocks, account_id <- students, reduce: {0, 0, 0} do
        {slacking_acc, struggling_acc, integrity_acc} ->
          flags = student_block_flags(block, account_id, index)

          {slacking_acc + flags.slacking_count, struggling_acc + flags.struggling_count,
           integrity_acc + flags.integrity_count}
      end

    %{
      section_id: section.id,
      section_title: section.title,
      slacking_count: slacking_count,
      struggling_count: struggling_count,
      integrity_count: integrity_count
    }
  end

  @doc """
  A 7x24 activity heatmap (day of week x hour of day, app timezone) for every raw
  event a cohort produced across `course_id` - not a per-block metric, a
  "when is this cohort actually working" view, the kind of procrastination/
  crunch pattern Moodle's engagement analytics and GitHub-style
  contribution grids both surface. Counts every event type, not just dwell,
  since the question is "is anyone active right now", not "how long did
  they stay". `day_of_week` is `Date.day_of_week/1`'s convention (`1` =
  Monday .. `7` = Sunday); the hour bucket is the hour of `occurred_at` in
  the app timezone (`Athena.TimeZones.app_timezone/0`) - a known
  simplification, students' own timezones aren't considered.
  Always returns the full 168-cell grid, zeros
  included, so a chart never has to guess whether a missing cell means "no
  data" or "not computed".
  """
  @spec activity_heatmap(binary(), binary(), keyword()) :: [
          %{day_of_week: 1..7, hour: 0..23, count: non_neg_integer()}
        ]
  def activity_heatmap(cohort_id, course_id, opts \\ []) do
    since = Keyword.get(opts, :since, default_since())
    index = build_scope_index(course_id, cohort_id, since, opts)
    heatmap_cells(index.hour_matrix)
  end

  defp heatmap_cells(hour_matrix) do
    for day <- 1..7, hour <- 0..23 do
      %{day_of_week: day, hour: hour, count: Map.get(hour_matrix, {day, hour}, 0)}
    end
  end

  @doc """
  The whole-course counterpart to `funnel/2`'s single-block drop-off: for
  every section of `course_id`, how many distinct students opened it,
  actually interacted with any block in it, and completed every block in
  it - the "Open edX Insights learner engagement funnel" view, showing
  where in the *course* (not just one block) a cohort thins out. `opened`/
  `interacted` use the exact same event-type sets `funnel/2` uses, widened
  from one block to the whole section; `completed` is only checked among
  students who opened the section at all, resolving to the shared team
  completion record (not an individual one) when `cohort_id` is a `:team`
  cohort, via `team_scope_id/1`.
  """
  @spec course_funnel(binary(), binary(), keyword()) :: [
          %{
            section_id: binary(),
            section_title: String.t(),
            opened: non_neg_integer(),
            interacted: non_neg_integer(),
            completed: non_neg_integer()
          }
        ]
  def course_funnel(cohort_id, course_id, opts \\ []) do
    since = Keyword.get(opts, :since, default_since())

    course_id
    |> build_scope_index(cohort_id, since, opts)
    |> course_funnel_from_index(cohort_id)
  end

  # Completion is resolved in one bulk query for every student who opened
  # anything in scope.
  defp course_funnel_from_index(index, cohort_id) do
    openers =
      for {{account_id, _block_id}, acc} <- index.acc_by_account_block,
          acc.enter_count > 0,
          into: MapSet.new(),
          do: account_id

    completed_by_account =
      Learning.completed_block_ids_by_account(
        MapSet.to_list(openers),
        Enum.map(index.all_blocks, & &1.id),
        team_scope_id(cohort_id)
      )

    accs_by_block =
      Enum.group_by(
        index.acc_by_account_block,
        fn {{_account_id, block_id}, _acc} -> block_id end,
        fn {{account_id, _block_id}, acc} -> {account_id, acc} end
      )

    Enum.map(index.sections, &section_funnel(&1, index, accs_by_block, completed_by_account))
  end

  defp section_funnel(section, index, accs_by_block, completed_by_account) do
    block_ids = index.blocks_by_section |> Map.get(section.id, []) |> Enum.map(& &1.id)
    accs = Enum.flat_map(block_ids, &Map.get(accs_by_block, &1, []))

    opened =
      for {account_id, acc} <- accs, acc.enter_count > 0, into: MapSet.new(), do: account_id

    interacted =
      for({account_id, acc} <- accs, acc.interact_count > 0, into: MapSet.new(), do: account_id)
      |> MapSet.intersection(opened)

    completed_count =
      Enum.count(opened, fn account_id ->
        completed_ids = Map.get(completed_by_account, account_id, MapSet.new())
        block_ids != [] and Enum.all?(block_ids, &MapSet.member?(completed_ids, &1))
      end)

    %{
      section_id: section.id,
      section_title: section.title,
      opened: MapSet.size(opened),
      interacted: MapSet.size(interacted),
      completed: completed_count
    }
  end

  @doc """
  The "is anyone even here" pulse chart every LMS admin view leads with
  (Moodle's Logs report, Canvas New Analytics' page-view trend): one row
  per calendar day that had at least one event anywhere in `course_id`,
  counting distinct `account_id`s that day - a DAU (daily active students)
  reading. Only days with activity are returned (not a zero-filled
  calendar range). Day boundaries are app-timezone calendar days, the same
  simplification `activity_heatmap/3` already documents.
  """
  @spec active_students_trend(binary(), binary(), keyword()) :: [
          %{date: Date.t(), active_count: non_neg_integer()}
        ]
  def active_students_trend(cohort_id, course_id, opts \\ []) do
    since = Keyword.get(opts, :since, default_since())
    index = build_scope_index(course_id, cohort_id, since, opts)
    trend_points(index.active_by_day)
  end

  defp trend_points(active_by_day) do
    active_by_day
    |> Enum.map(fn {date, count} -> %{date: date, active_count: count} end)
    |> Enum.sort_by(& &1.date, Date)
  end

  @doc """
  For every nudge `reason` actually observed in scope, how many times it
  fired and, of those, how many times the *same* student did **not**
  trigger the *same*-named flag again on any block visited afterward - an
  ASSISTments-style "did the hint change the next attempt" measure, applied
  to nudges instead of hints.

  `reason` is read straight from each `nudge_shown` event's payload
  (`"fast_dwell"`, `"shallow_scroll"`, `"heavy_paste"`, `"video_skipped"` -
  `player.ex` passes the flag name itself as the reason, so no separate
  mapping table is needed here); "corrected" means that same flag never
  fires for that student on any of the course's blocks, counting only what
  they did strictly after the nudge. `correction_rate` is `nil` (not
  `0.0`) when `nudged_count` is `0` - nothing to divide, not "0% effective".

  Needs exact event times, so it always reads raw events - but only the
  nudges themselves and the nudged students' later activity.
  """
  @spec nudge_correction_rate(binary(), binary(), keyword()) :: [
          %{
            reason: atom(),
            nudged_count: non_neg_integer(),
            corrected_count: non_neg_integer(),
            correction_rate: float() | nil
          }
        ]
  def nudge_correction_rate(cohort_id, course_id, opts \\ []) do
    cached(:nudge_correction_rate, cohort_id, course_id, opts, fn ->
      since = Keyword.get(opts, :since, default_since())

      course_id
      |> build_scope_index(cohort_id, since, Keyword.put(opts, :source, :structure_only))
      |> nudge_correction_rate_from_index()
    end)
  end

  defp nudge_correction_rate_from_index(index) do
    block_ids = Enum.map(index.all_blocks, & &1.id)
    since = index.from_day && TimeZones.start_of_day(index.from_day)

    nudges =
      Events.list_events_for_scope(block_ids, index.cohort_id, since, event_types: [:nudge_shown])

    reasons = nudges |> Enum.map(&nudge_reason/1) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    # Only blocks where one of the observed reasons could fire again at all.
    candidate_ids =
      for block <- index.all_blocks,
          Enum.any?(reasons, &can_fire?(&1, block, index)),
          do: block.id

    later_events =
      case {nudges, candidate_ids} do
        {[], _} ->
          %{}

        {_, []} ->
          %{}

        {nudges, candidate_ids} ->
          first_nudge_at = nudges |> Enum.map(& &1.occurred_at) |> Enum.min(DateTime)

          candidate_ids
          |> Events.list_events_for_scope(index.cohort_id, first_nudge_at,
            account_ids: nudges |> Enum.map(& &1.account_id) |> Enum.uniq()
          )
          |> Enum.group_by(&{&1.account_id, &1.block_id})
      end

    blocks_by_id = Map.new(index.all_blocks, &{&1.id, &1})

    nudges
    |> Enum.map(&{nudge_reason(&1), &1})
    |> Enum.reject(fn {reason, _event} -> is_nil(reason) end)
    |> Enum.group_by(fn {reason, _event} -> reason end, fn {_reason, event} -> event end)
    |> Enum.map(fn {reason, nudges} ->
      reason_correction(reason, nudges, later_events, blocks_by_id, index)
    end)
  end

  defp nudge_reason(%{payload: %{"reason" => reason}}) when is_binary(reason) do
    String.to_existing_atom(reason)
  rescue
    ArgumentError -> nil
  end

  defp nudge_reason(_event), do: nil

  defp reason_correction(reason, nudges, later_events, blocks_by_id, index) do
    nudged_count = length(nudges)

    corrected_count =
      Enum.count(nudges, &(!flag_fires_again?(reason, &1, later_events, blocks_by_id, index)))

    %{
      reason: reason,
      nudged_count: nudged_count,
      corrected_count: corrected_count,
      correction_rate: rate(corrected_count, nudged_count)
    }
  end

  # Only blocks that can fire `reason` at all, and only their own events
  # after the nudge: slacking flags never depend on the rest of the section
  # (backtracking is a struggling signal), so no section context is needed.
  defp flag_fires_again?(reason, nudge, later_events, blocks_by_id, index) do
    after_at = DateTime.add(nudge.occurred_at, 1, :second)

    Enum.any?(later_events, fn
      {{account_id, block_id}, events} when account_id == nudge.account_id ->
        block = Map.fetch!(blocks_by_id, block_id)

        can_fire?(reason, block, index) and
          events
          |> Enum.filter(&(DateTime.compare(&1.occurred_at, after_at) != :lt))
          |> fires_on_block?(reason, block, index)

      _other ->
        false
    end)
  end

  defp fires_on_block?([], _reason, _block, _index), do: false

  defp fires_on_block?(events, reason, block, index) do
    events
    |> Accumulator.build()
    |> Accumulator.by_account_block()
    |> Map.values()
    |> Accumulator.merge_all()
    |> then(&(reason in block_flags(block, &1, index).slacking))
  end

  defp can_fire?(:fast_dwell, block, index),
    do: Map.fetch!(index.resolved_rule_by_block_id, block.id)[:expected_seconds] != nil

  defp can_fire?(:shallow_scroll, block, _index), do: block.type == :text
  defp can_fire?(:heavy_paste, block, _index), do: block.type in [:quiz_question, :code]
  defp can_fire?(:video_skipped, block, _index), do: block.type == :video
  defp can_fire?(:no_debug_cycle, block, _index), do: block.type == :code
  defp can_fire?(_reason, _block, _index), do: true

  # Windows are whole days (see the moduledoc), so the window's first day -
  # not the exact `since` instant - is what identifies a result. Forced raw
  # reads (`source: :raw`) bypass the cache.
  defp cached(name, cohort_id, course_id, opts, fun) do
    if Keyword.get(opts, :source) == :raw do
      fun.()
    else
      since = Keyword.get(opts, :since, default_since())
      from_day = since && since |> TimeZones.to_app_zone() |> DateTime.to_date()

      key =
        {name, cohort_id, course_id, from_day, Keyword.get(opts, :section_id),
         Keyword.get(opts, :include_nudges, true)}

      DashboardCache.fetch(key, fun)
    end
  end

  defp radar_blocks(index, nil), do: index.all_blocks
  defp radar_blocks(index, section_id), do: Map.get(index.blocks_by_section, section_id, [])

  defp student_radar_row(account_id, completed_ids, blocks, index) do
    flagged_blocks =
      blocks
      |> Enum.map(&student_block_flags(&1, account_id, index))
      |> Enum.filter(&(&1.flags != []))

    slacking_index = flagged_blocks |> Enum.map(& &1.slacking_count) |> Enum.sum()
    struggling_index = flagged_blocks |> Enum.map(& &1.struggling_count) |> Enum.sum()
    integrity_index = flagged_blocks |> Enum.map(& &1.integrity_count) |> Enum.sum()
    config = engagement_config()

    status =
      cond do
        # Checked first, and with a lower bar than slacking/struggling - a
        # single academic-integrity flag (a printscreen/copy attempt during
        # an exam) is worth a teacher's attention immediately, unlike
        # slacking/struggling which only matter as a repeated pattern.
        integrity_index >= Keyword.get(config, :student_radar_integrity_threshold, 1) -> :red
        slacking_index >= Keyword.get(config, :student_radar_slacking_threshold, 2) -> :red
        struggling_index >= Keyword.get(config, :student_radar_struggling_threshold, 2) -> :yellow
        true -> :green
      end

    %{
      account_id: account_id,
      progress_percent: progress_percent(completed_ids, blocks),
      slacking_index: slacking_index,
      struggling_index: struggling_index,
      integrity_index: integrity_index,
      status: status,
      flagged_blocks: flagged_blocks
    }
  end

  # A block the student never touched has no accumulator and can't fire
  # anything - the common case on a cohort-wide grid.
  defp student_block_flags(block, account_id, index) do
    {flags, metrics} =
      case Map.get(index.acc_by_account_block, {account_id, block.id}) do
        nil ->
          {%{slacking: [], struggling: [], integrity: []}, %{}}

        acc ->
          metrics = student_block_metrics(block, acc, index)
          {flag_concerns(metrics), metrics}
      end

    all_flags = flags.slacking ++ flags.struggling ++ flags.integrity

    %{
      block_id: block.id,
      block_type: block.type,
      details: Map.new(all_flags, &{&1, flag_detail(&1, metrics)}),
      section_id: block.section_id,
      flags: flags.slacking ++ flags.struggling ++ flags.integrity,
      slacking_flags: flags.slacking,
      struggling_flags: flags.struggling,
      integrity_flags: flags.integrity,
      slacking_count: length(flags.slacking),
      struggling_count: length(flags.struggling),
      integrity_count: length(flags.integrity)
    }
  end

  defp block_flags(block, acc, index) do
    block |> student_block_metrics(acc, index) |> flag_concerns()
  end

  defp student_block_metrics(block, acc, index) do
    acc
    |> Accumulator.to_metrics(block.type, Map.fetch!(index.resolved_rule_by_block_id, block.id))
    |> with_group_baselines(Map.get(index.baselines, block.id))
  end

  # Whole-course fact, not a windowed behavior. `completed_ids` comes from
  # one bulk `Athena.Learning.completed_block_ids_by_account/3` call for the
  # whole cohort (same team-vs-individual scoping rule as the Player's own
  # `completed_block_ids/3` waterline), already restricted to `blocks`.
  defp progress_percent(_completed_ids, []), do: 0.0

  defp progress_percent(completed_ids, blocks) do
    MapSet.size(completed_ids) / length(blocks) * 100
  end

  # `cohort_id` is `nil` for a self-paced/no-cohort scope, or an
  # `:academic` cohort's id (individual completion records either way).
  # Only a `:team` cohort's completion records are keyed by cohort id
  # (see `Athena.Learning.Progress.mark_completed/3`), so this is the one
  # place that decides whether a scope's `cohort_id` should also be used as
  # the `team_id` passed to `Athena.Learning.completed_block_ids/3`.
  defp team_scope_id(nil), do: nil

  defp team_scope_id(cohort_id) do
    case Learning.get_cohorts_map([cohort_id]) do
      %{^cohort_id => %{type: :team}} -> cohort_id
      _ -> nil
    end
  end

  defp default_since do
    engagement_config()
    |> Keyword.get(:student_radar_default_window_days, 7)
    |> window_start()
  end

  @doc """
  Start of a "last `days` days" window: midnight (app timezone) of the day
  `days - 1` days ago, so the window is today plus `days - 1` whole days.
  """
  @spec window_start(pos_integer()) :: DateTime.t()
  def window_start(days) when days >= 1 do
    TimeZones.today() |> Date.add(-(days - 1)) |> TimeZones.start_of_day()
  end

  @doc """
  Classifies an already-computed metrics map (from `get_metrics/1`) into
  independent flag lists, per the plan's Rapid Guessing (Wise), Gaming the
  System (Baker, 2004), and Self-Regulated Learning framing:

  - `:content` - meaningful on a *cohort-wide* metrics map (no `account_id`
    filter): a high rate here across most students means the material is
    the problem, not any one student.
  - `:slacking` / `:struggling` - meaningful on a *per-student* metrics map
    (`account_id` filter applied): two deliberately non-overlapping student
    indices - "gaming/rapid-guessing" signals vs. "stuck, but trying"
    signals. Backtracking only ever lands in `:struggling` (returning to
    theory after a wrong turn is a sign of self-regulated learning, not
    avoidance) and never in `:slacking`.

  All thresholds come from `config :athena, Athena.Engagement` so they can
  be recalibrated after the pilot without a code change.
  """
  @spec flag_concerns(map()) :: %{
          content: [atom()],
          slacking: [atom()],
          struggling: [atom()],
          integrity: [atom()]
        }
  def flag_concerns(metrics) do
    config = engagement_config()

    %{
      content: content_flags(metrics, config),
      slacking: slacking_flags(metrics, config),
      struggling: struggling_flags(metrics, config),
      integrity: integrity_flags(metrics, config)
    }
  end

  defp content_flags(metrics, config) do
    []
    |> add_if(
      metrics[:backtrack_rate],
      &(&1 > Keyword.get(config, :concern_backtrack_rate_threshold, 0.4)),
      :high_backtrack_rate
    )
    |> add_if(
      metrics[:hesitation_rate],
      &(&1 > Keyword.get(config, :concern_hesitation_rate_threshold, 0.4)),
      :high_hesitation_rate
    )
  end

  defp slacking_flags(metrics, config) do
    no_debug_cycle? =
      metrics[:debug_cycle_present?] == false and is_number(metrics[:paste_ratio]) and
        metrics[:paste_ratio] > 0

    []
    |> add_if_true(fast_dwell?(metrics, config), :fast_dwell)
    |> add_if(
      metrics[:avg_scroll_depth_percent],
      &(&1 < Keyword.get(config, :min_scroll_percent_for_text, 70)),
      :shallow_scroll
    )
    |> add_if(
      metrics[:paste_ratio],
      &(&1 > Keyword.get(config, :paste_ratio_nudge_threshold, 0.8)),
      :heavy_paste
    )
    |> add_if(
      metrics[:skip_ratio],
      &(&1 > Keyword.get(config, :video_skip_ratio_threshold, 0.3)),
      :video_skipped
    )
    |> add_if_true(no_debug_cycle?, :no_debug_cycle)
  end

  defp struggling_flags(metrics, config) do
    []
    |> add_if_true(slow_dwell?(metrics, config), :slow_dwell)
    |> add_if_true(hesitation?(metrics, config), :hesitation)
    |> add_if(metrics[:backtrack_count], &(&1 > 0), :backtracked)
    |> add_if_true(metrics[:panic_debugging?] == true, :panic_debugging)
  end

  # Only ever fires on `exam_metrics/1`'s output (`quiz_exam`/`ticket_exam`
  # blocks) - every key read here is exam-prefixed or exam-exclusive (see
  # the comment on `exam_metrics/1`), so this silently no-ops (via `add_if`'s
  # `nil` clause) for every other block type's metrics map. Deliberately
  # simple absolute thresholds, same idiom as every other flag in this
  # module - this feeds the *dashboard* (student radar, course-wide flag
  # rates), a lightweight "worth a look" indicator for any teacher browsing
  # engagement analytics. It is not the same decision that drives the live
  # per-attempt risk badge a grader acts on (reject, zero the score) - that
  # one needs the cohort-relative, percentile-normalized comparison in
  # `Athena.Engagement.Proctoring`/`ExamIntegrityStats`, precisely because a
  # single absolute threshold here would flag an anxious student who
  # revised their answer a lot exactly like it would flag someone who
  # actually tried to cheat.
  defp integrity_flags(metrics, config) do
    []
    |> add_if(metrics[:printscreen_count], &(&1 > 0), :printscreen_attempted)
    |> add_if(metrics[:copy_attempt_count], &(&1 > 0), :copy_attempted)
    |> add_if(metrics[:cut_attempt_count], &(&1 > 0), :cut_attempted)
    |> add_if(metrics[:multi_tab_count], &(&1 > 0), :multi_tab_detected)
    |> add_if(
      metrics[:focus_loss_count],
      &(&1 >= Keyword.get(config, :exam_focus_loss_threshold, 3)),
      :excessive_tab_switching
    )
    |> add_if(
      metrics[:exam_paste_ratio],
      &(&1 > Keyword.get(config, :exam_paste_ratio_threshold, 0.6)),
      :heavy_paste_on_exam
    )
  end

  # Time on a block is judged against the teacher's own expectation when the
  # block has one (`expected_seconds`), otherwise against the cohort's
  # median time on that same block (`dwell_group_ratio`, only present once
  # enough students have data - see `with_group_baselines/2`).
  defp fast_dwell?(metrics, config) do
    cond do
      is_number(metrics[:dwell_ratio]) ->
        metrics[:dwell_ratio] < Keyword.get(config, :concern_dwell_ratio_threshold, 0.5)

      is_number(metrics[:dwell_group_ratio]) ->
        metrics[:dwell_group_ratio] < Keyword.get(config, :group_fast_dwell_ratio, 0.4)

      true ->
        false
    end
  end

  defp slow_dwell?(metrics, config) do
    cond do
      is_number(metrics[:dwell_ratio]) ->
        metrics[:dwell_ratio] > Keyword.get(config, :slow_dwell_ratio_threshold, 2.0)

      is_number(metrics[:dwell_group_ratio]) ->
        metrics[:dwell_group_ratio] > Keyword.get(config, :group_slow_dwell_ratio, 2.5)

      true ->
        false
    end
  end

  # Changing an answer once is normal. It only counts as hesitation from
  # `hesitation_min_changes` changes on, *and* more than most of the cohort
  # (`hesitation_group_baseline`, their 80th percentile) - or, with too few
  # peers to compare against, from `hesitation_absolute_changes` on.
  defp hesitation?(metrics, config) do
    changes = metrics[:answer_change_count]

    cond do
      not is_integer(changes) ->
        false

      changes < Keyword.get(config, :hesitation_min_changes, 2) ->
        false

      is_number(metrics[:hesitation_group_baseline]) ->
        changes > metrics[:hesitation_group_baseline]

      true ->
        changes >= Keyword.get(config, :hesitation_absolute_changes, 3)
    end
  end

  @doc """
  Adds the cohort comparison a student's metrics on one block are judged
  against (`flag_concerns/1` reads them): `dwell_group_ratio` (their average
  time over the cohort median) and `hesitation_group_baseline` (the
  cohort's 80th-percentile answer changes), each only when `baseline` has
  enough peers behind it.
  """
  @spec with_group_baselines(map(), map() | nil) :: map()
  def with_group_baselines(metrics, nil), do: metrics

  def with_group_baselines(metrics, baseline) do
    metrics
    |> put_dwell_baseline(baseline)
    |> Map.put(:hesitation_group_baseline, baseline[:answer_changes_p80])
    |> Map.put(:group_peers, baseline[:peers])
  end

  defp put_dwell_baseline(metrics, %{dwell_median: median})
       when is_number(median) and median > 0 do
    case metrics[:avg_dwell_seconds] do
      nil -> Map.put(metrics, :dwell_group_median, median)
      avg -> Map.merge(metrics, %{dwell_group_median: median, dwell_group_ratio: avg / median})
    end
  end

  defp put_dwell_baseline(metrics, _baseline), do: metrics

  @doc """
  What a student's flag on one block was measured as, against what - the
  raw material for a human explanation. `basis` says how it was judged:
  `:expected` (the teacher's expected time), `:group` (the cohort, with
  `peers` students compared), `:absolute` (a fixed limit), `:count` (it
  happened at all) or `:pattern` (a shape of behaviour, no single number).
  """
  @spec flag_detail(atom(), map()) :: map()
  def flag_detail(flag, metrics) when flag in [:fast_dwell, :slow_dwell] do
    if is_number(metrics[:dwell_ratio]) do
      %{
        value: metrics[:avg_dwell_seconds],
        baseline:
          metrics[:avg_dwell_seconds] && metrics[:avg_dwell_seconds] / metrics[:dwell_ratio],
        basis: :expected
      }
    else
      %{
        value: metrics[:avg_dwell_seconds],
        baseline: metrics[:dwell_group_median],
        basis: :group,
        peers: metrics[:group_peers]
      }
    end
  end

  def flag_detail(:shallow_scroll, metrics),
    do: absolute(metrics[:avg_scroll_depth_percent], :min_scroll_percent_for_text, 70)

  def flag_detail(:heavy_paste, metrics),
    do: absolute(metrics[:paste_ratio], :paste_ratio_nudge_threshold, 0.8)

  def flag_detail(:video_skipped, metrics),
    do: absolute(metrics[:skip_ratio], :video_skip_ratio_threshold, 0.3)

  def flag_detail(:hesitation, metrics) do
    case metrics[:hesitation_group_baseline] do
      nil ->
        absolute(metrics[:answer_change_count], :hesitation_absolute_changes, 3)

      baseline ->
        %{
          value: metrics[:answer_change_count],
          baseline: baseline,
          basis: :group,
          peers: metrics[:group_peers]
        }
    end
  end

  def flag_detail(:backtracked, metrics),
    do: %{value: metrics[:backtrack_count], basis: :count}

  def flag_detail(:excessive_tab_switching, metrics),
    do: absolute(metrics[:focus_loss_count], :exam_focus_loss_threshold, 3)

  def flag_detail(:heavy_paste_on_exam, metrics),
    do: absolute(metrics[:exam_paste_ratio], :exam_paste_ratio_threshold, 0.6)

  def flag_detail(:printscreen_attempted, metrics),
    do: %{value: metrics[:printscreen_count], basis: :count}

  def flag_detail(:copy_attempted, metrics),
    do: %{value: metrics[:copy_attempt_count], basis: :count}

  def flag_detail(:cut_attempted, metrics),
    do: %{value: metrics[:cut_attempt_count], basis: :count}

  def flag_detail(:multi_tab_detected, metrics),
    do: %{value: metrics[:multi_tab_count], basis: :count}

  def flag_detail(:panic_debugging, metrics),
    do: %{value: metrics[:run_attempt_count], basis: :pattern}

  def flag_detail(:no_debug_cycle, metrics),
    do: %{value: metrics[:paste_ratio], basis: :pattern}

  def flag_detail(_flag, _metrics), do: %{basis: :pattern}

  defp absolute(value, config_key, default) do
    %{
      value: value,
      baseline: Keyword.get(engagement_config(), config_key, default),
      basis: :absolute
    }
  end

  defp add_if(flags, nil, _condition?, _flag), do: flags
  defp add_if(flags, value, condition?, flag), do: add_if_true(flags, condition?.(value), flag)

  defp add_if_true(flags, true, flag), do: [flag | flags]
  defp add_if_true(flags, _falsy, _flag), do: flags
  defp rate(_count, 0), do: nil
  defp rate(count, total), do: count / total

  defp filter_by_account(events, nil), do: events

  defp filter_by_account(events, account_id),
    do: Enum.filter(events, &(&1.account_id == account_id))

  defp distinct_accounts(events, filter_fun) do
    events |> Enum.filter(filter_fun) |> Enum.map(& &1.account_id) |> MapSet.new()
  end

  defp engagement_config, do: Application.get_env(:athena, Athena.Engagement, [])

  defp avg([]), do: nil
  defp avg(list), do: Enum.sum(list) / length(list)

  defp week_start(%{occurred_at: occurred_at}) do
    date = occurred_at |> TimeZones.to_app_zone() |> DateTime.to_date()
    Date.add(date, -(Date.day_of_week(date) - 1))
  end

  defp time_series_value(:avg_dwell_seconds, events),
    do: events |> Events.pair_viewport_dwells() |> Enum.map(&elem(&1, 2)) |> avg()

  defp time_series_value(:sample_size, events),
    do: events |> Events.pair_viewport_dwells() |> length()

  defp time_series_value(:nudge_shown_count, events),
    do: Enum.count(events, &(&1.event_type == :nudge_shown))

  defp pearson(pairs) when length(pairs) < 2, do: nil

  defp pearson(pairs) do
    xs = Enum.map(pairs, &elem(&1, 0))
    ys = Enum.map(pairs, &elem(&1, 1))
    n = length(pairs)

    mean_x = Enum.sum(xs) / n
    mean_y = Enum.sum(ys) / n

    covariance = pairs |> Enum.map(fn {x, y} -> (x - mean_x) * (y - mean_y) end) |> Enum.sum()
    variance_x = xs |> Enum.map(&:math.pow(&1 - mean_x, 2)) |> Enum.sum()
    variance_y = ys |> Enum.map(&:math.pow(&1 - mean_y, 2)) |> Enum.sum()

    denominator = :math.sqrt(variance_x * variance_y)

    if denominator == 0.0, do: nil, else: covariance / denominator
  end
end
