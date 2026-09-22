defmodule Athena.Engagement.Metrics do
  @moduledoc """
  Turns raw `Athena.Engagement.Event` rows into the metric catalog: per-block
  numbers a teacher or researcher can actually read, computed on demand
  (`group_by`-style, no cache/materialized table - same style as
  `Athena.Learning.Submissions.get_team_leaderboard/1`).

  `get_metrics/1` is the one entry point meant for a future dashboard (a
  course-tree node plus an optional cohort/student filter); `funnel/2`,
  `correlate/2`, and `time_series/3` are the other four "analysis methods"
  from the plan (percentile is handled separately, in
  `Athena.Engagement.evaluate_nudge/5`/`BlockStats`, since that one needs to
  be cheap enough to run on every dwell, not just on a dashboard load).

  This first cut covers the metrics computable purely from events already
  captured client-side (see `Athena.Engagement.Event`'s catalog) - dwell,
  scroll depth, paste ratio, video controls, tab focus, attachment/image
  interaction, and the flagship "backtracked to an earlier block" signal.
  Metrics that need `Athena.Learning.Submission` data too (first-attempt
  correctness, time-to-answer relative to a deadline, exam score
  trajectories) are intentionally left for a follow-up once `Submission`
  data is wired into the same scope - the per-type dispatch below
  (`text_metrics/2`, `video_metrics/2`, ...) is exactly where they'd be
  added, one function at a time, without touching the entry points.
  """

  alias Athena.Content
  alias Athena.Content.Policy
  alias Athena.Engagement.Events
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
      section_blocks =
        section.id |> Content.list_blocks_by_section(:all) |> Enum.sort_by(& &1.order)

      section_events = events_for_scope(section_blocks, scope)
      block_events = Enum.filter(section_events, &(&1.block_id == block.id))
      resolved_rule = Policy.resolve_engagement_rule(block, section)

      compute_block_metrics(
        block,
        section,
        section_blocks,
        block_events,
        section_events,
        resolved_rule
      )
    else
      _ -> %{}
    end
  end

  def get_metrics(%{resource_type: :section, resource_id: section_id} = scope) do
    case Content.get_section(section_id) do
      {:ok, section} ->
        section_blocks =
          section_id |> Content.list_blocks_by_section(:all) |> Enum.sort_by(& &1.order)

        section_events = events_for_scope(section_blocks, scope)

        Map.new(section_blocks, fn block ->
          block_events = Enum.filter(section_events, &(&1.block_id == block.id))
          resolved_rule = Policy.resolve_engagement_rule(block, section)

          {block.id,
           compute_block_metrics(
             block,
             section,
             section_blocks,
             block_events,
             section_events,
             resolved_rule
           )}
        end)

      _ ->
        %{}
    end
  end

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
  course, for every student in the given cohorts - the shape method 5
  ("cross-cohort comparison") needs for a statistics package (R/
  Python/SPSS): every metric as its own column, plus `cohort_id` so groups
  can be compared. Not wired into any UI yet (see the CSV controller/route
  that will call this) - not a priority for the September pilot, but shaped
  now so the aggregation model doesn't need to change later just to support
  export.
  """
  @spec export_wide_table(binary(), [binary()]) :: [map()]
  def export_wide_table(course_id, cohort_ids) do
    blocks = course_blocks(course_id)

    for block <- blocks,
        cohort_id <- cohort_ids,
        account_id <- students_in_cohort(cohort_id) do
      scope = %{
        resource_type: :block,
        resource_id: block.id,
        cohort_id: cohort_id,
        account_id: account_id
      }

      get_metrics(scope)
      |> Map.merge(%{
        cohort_id: cohort_id,
        account_id: account_id,
        block_id: block.id,
        block_type: block.type
      })
    end
  end

  defp course_blocks(course_id) do
    course_id
    |> Content.get_course_tree(:all)
    |> flatten_sections()
    |> Enum.flat_map(&Content.list_blocks_by_section(&1.id, :all))
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

  # Fetches every section, block, and matching event for a whole course in a
  # fixed, small number of queries (one for sections, one bulk query for
  # blocks, one bulk query for events), then indexes them in memory - the
  # shared foundation for every course-wide aggregate below
  # (`section_flag_totals/3`, `nudge_correction_rate/3`,
  # `cohort_flag_profile/3`, `student_radar/3`), all of which used to
  # re-fetch a block's own section and section-blocks, and re-query events,
  # once per (block, student) pair (an O(sections x blocks x students) DB
  # round-trip count). `student_block_flags/4` reads this index instead of
  # touching the database at all.
  defp build_scope_index(course_id, cohort_id, since) do
    sections = course_id |> Content.get_course_tree(:all) |> flatten_sections()
    section_by_id = Map.new(sections, &{&1.id, &1})

    blocks_by_section =
      sections
      |> Enum.map(& &1.id)
      |> Content.list_blocks_by_section_ids()
      |> Enum.group_by(& &1.section_id)
      |> Map.new(fn {section_id, blocks} -> {section_id, Enum.sort_by(blocks, & &1.order)} end)

    all_blocks = blocks_by_section |> Map.values() |> List.flatten()
    all_block_ids = Enum.map(all_blocks, & &1.id)
    block_to_section_id = Map.new(all_blocks, &{&1.id, &1.section_id})

    all_events = Events.list_events_for_scope(all_block_ids, cohort_id, since)
    events_by_block = Enum.group_by(all_events, & &1.block_id)
    events_by_section = Enum.group_by(all_events, &Map.fetch!(block_to_section_id, &1.block_id))

    resolved_rule_by_block_id =
      Map.new(all_blocks, fn block ->
        section = Map.fetch!(section_by_id, block.section_id)
        {block.id, Policy.resolve_engagement_rule(block, section)}
      end)

    %{
      sections: sections,
      section_by_id: section_by_id,
      blocks_by_section: blocks_by_section,
      events_by_block: events_by_block,
      events_by_section: events_by_section,
      resolved_rule_by_block_id: resolved_rule_by_block_id
    }
  end

  defp filter_since(events, nil), do: events

  defp filter_since(events, since),
    do: Enum.filter(events, &(DateTime.compare(&1.occurred_at, since) != :lt))

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
    since = Keyword.get(opts, :since, default_since())
    index = build_scope_index(course_id, cohort_id, since)
    blocks = radar_blocks(index, Keyword.get(opts, :section_id))
    team_id = team_scope_id(cohort_id)

    cohort_id
    |> students_in_cohort()
    |> Enum.map(&student_radar_row(&1, team_id, blocks, index))
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
    :panic_debugging
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
  `student_block_flags/4` grid `student_radar/3` already builds, just
  tallied by flag name instead of by student, so a cohort's radar profile
  and its "Student Radar" table can never silently disagree about what
  counts as a flag firing.
  """
  @spec cohort_flag_profile(binary(), binary(), keyword()) :: %{atom() => float()}
  def cohort_flag_profile(cohort_id, course_id, opts \\ []) do
    since = Keyword.get(opts, :since, default_since())
    index = build_scope_index(course_id, cohort_id, since)
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
  full course (unlike `student_radar/3`/`cohort_flag_profile/3`, a single
  section's own total wouldn't need a per-section breakdown), returned in
  the same course order `course_blocks/1`'s traversal already relies on.
  """
  @spec section_flag_totals(binary(), binary(), keyword()) :: [
          %{
            section_id: binary(),
            section_title: String.t(),
            slacking_count: non_neg_integer(),
            struggling_count: non_neg_integer()
          }
        ]
  def section_flag_totals(cohort_id, course_id, opts \\ []) do
    since = Keyword.get(opts, :since, default_since())
    students = students_in_cohort(cohort_id)
    index = build_scope_index(course_id, cohort_id, since)

    Enum.map(index.sections, fn section -> section_flag_total(section, students, index) end)
  end

  defp section_flag_total(section, students, index) do
    blocks = Map.get(index.blocks_by_section, section.id, [])

    {slacking_count, struggling_count} =
      for block <- blocks, account_id <- students, reduce: {0, 0} do
        {slacking_acc, struggling_acc} ->
          flags = student_block_flags(block, account_id, index)
          {slacking_acc + flags.slacking_count, struggling_acc + flags.struggling_count}
      end

    %{
      section_id: section.id,
      section_title: section.title,
      slacking_count: slacking_count,
      struggling_count: struggling_count
    }
  end

  @doc """
  A 7x24 activity heatmap (day of week x hour of day, UTC) for every raw
  event a cohort produced across `course_id` - not a per-block metric, a
  "when is this cohort actually working" view, the kind of procrastination/
  crunch pattern Moodle's engagement analytics and GitHub-style
  contribution grids both surface. Counts every event type, not just dwell,
  since the question is "is anyone active right now", not "how long did
  they stay". `day_of_week` is `Date.day_of_week/1`'s convention (`1` =
  Monday .. `7` = Sunday); the hour bucket is the UTC hour of `occurred_at`
  - a known simplification (no per-student timezone data is collected).
  Always returns the full 168-cell grid, zeros
  included, so a chart never has to guess whether a missing cell means "no
  data" or "not computed".
  """
  @spec activity_heatmap(binary(), binary(), keyword()) :: [
          %{day_of_week: 1..7, hour: 0..23, count: non_neg_integer()}
        ]
  def activity_heatmap(cohort_id, course_id, opts \\ []) do
    since = Keyword.get(opts, :since, default_since())
    block_ids = course_id |> course_blocks() |> Enum.map(& &1.id)

    counts =
      block_ids
      |> Events.list_events_for_scope(cohort_id, since)
      |> Enum.reduce(%{}, fn event, acc ->
        key = heatmap_cell(event.occurred_at)
        Map.update(acc, key, 1, &(&1 + 1))
      end)

    for day <- 1..7, hour <- 0..23 do
      %{day_of_week: day, hour: hour, count: Map.get(counts, {day, hour}, 0)}
    end
  end

  defp heatmap_cell(occurred_at) do
    {occurred_at |> DateTime.to_date() |> Date.day_of_week(), occurred_at.hour}
  end

  @doc """
  The whole-course counterpart to `funnel/2`'s single-block drop-off: for
  every section of `course_id`, how many distinct students opened it,
  actually interacted with any block in it, and completed every block in
  it - the "Open edX Insights learner engagement funnel" view, showing
  where in the *course* (not just one block) a cohort thins out. `opened`/
  `interacted` reuse the exact same event-type sets `funnel/2` already
  uses, just widened from one block's events to the whole section's;
  `completed` is only checked among students who opened the section at all
  (anyone who never opened it trivially hasn't completed it either), via
  the same `Athena.Learning.completed_block_ids/3` the Player's waterline
  and `student_radar/3`'s `progress_percent` already rely on - resolving to
  the shared team completion record (not an individual one) when
  `cohort_id` is a `:team` cohort, via `team_scope_id/1`.
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
    team_id = team_scope_id(cohort_id)

    course_id
    |> Content.get_course_tree(:all)
    |> flatten_sections()
    |> Enum.map(&section_funnel(&1, cohort_id, team_id, since))
  end

  defp section_funnel(section, cohort_id, team_id, since) do
    blocks = Content.list_blocks_by_section(section.id, :all)
    block_ids = Enum.map(blocks, & &1.id)
    events = Events.list_events_for_scope(block_ids, cohort_id, since)

    opened = distinct_accounts(events, &(&1.event_type == :viewport_enter))

    interacted =
      events
      |> distinct_accounts(
        &(&1.event_type in [
            :viewport_exit,
            :paste_detected,
            :video_play,
            :attachment_open,
            :image_zoom
          ])
      )
      |> MapSet.intersection(opened)

    completed_count =
      Enum.count(opened, fn account_id ->
        completed_ids = MapSet.new(Learning.completed_block_ids(account_id, section.id, team_id))
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
  calendar range) - a chart can still plot a sparse series, and this way
  the result never has to guess where "today" is relative to `opts[:since]`.
  Day boundaries are UTC calendar days, the same simplification
  `activity_heatmap/3` already documents.
  """
  @spec active_students_trend(binary(), binary(), keyword()) :: [
          %{date: Date.t(), active_count: non_neg_integer()}
        ]
  def active_students_trend(cohort_id, course_id, opts \\ []) do
    since = Keyword.get(opts, :since, default_since())
    block_ids = course_id |> course_blocks() |> Enum.map(& &1.id)

    block_ids
    |> Events.list_events_for_scope(cohort_id, since)
    |> Enum.group_by(&DateTime.to_date(&1.occurred_at))
    |> Enum.map(fn {date, events} ->
      %{date: date, active_count: events |> Enum.map(& &1.account_id) |> Enum.uniq() |> length()}
    end)
    |> Enum.sort_by(& &1.date, Date)
  end

  @doc """
  For every nudge `reason` actually observed in scope, how many times it
  fired and, of those, how many times the *same* student did **not**
  trigger the *same*-named flag again on any block visited afterward - an
  ASSISTments-style "did the hint change the next attempt" measure, applied
  to nudges instead of hints, and the one genuinely new piece of
  methodology in this batch (every other aggregation here is a re-fold of
  signals `flag_concerns/1` already defines).

  `reason` is read straight from each `nudge_shown` event's payload
  (`"fast_dwell"`, `"shallow_scroll"`, `"heavy_paste"`, `"video_skipped"` -
  `player.ex` passes the flag name itself as the reason, so no separate
  mapping table is needed here); "corrected" means `student_block_flags/4`
  never reports that same flag name for that student on any of the
  course's blocks at any point strictly after the nudge fired.
  `correction_rate` is `nil` (not `0.0`) when `nudged_count` is `0` -
  nothing to divide, not "0% effective".
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
    since = Keyword.get(opts, :since, default_since())
    index = build_scope_index(course_id, cohort_id, since)
    blocks = index.blocks_by_section |> Map.values() |> List.flatten()

    index.events_by_block
    |> Map.values()
    |> List.flatten()
    |> Enum.filter(&(&1.event_type == :nudge_shown))
    |> Enum.map(&{nudge_reason(&1), &1})
    |> Enum.reject(fn {reason, _event} -> is_nil(reason) end)
    |> Enum.group_by(fn {reason, _event} -> reason end, fn {_reason, event} -> event end)
    |> Enum.map(fn {reason, nudges} -> reason_correction(reason, nudges, blocks, index) end)
  end

  defp nudge_reason(%{payload: %{"reason" => reason}}) when is_binary(reason) do
    String.to_existing_atom(reason)
  rescue
    ArgumentError -> nil
  end

  defp nudge_reason(_event), do: nil

  defp reason_correction(reason, nudges, blocks, index) do
    nudged_count = length(nudges)
    corrected_count = Enum.count(nudges, &(!flag_fires_again?(reason, &1, blocks, index)))

    %{
      reason: reason,
      nudged_count: nudged_count,
      corrected_count: corrected_count,
      correction_rate: rate(corrected_count, nudged_count)
    }
  end

  defp flag_fires_again?(reason, nudge, blocks, index) do
    after_at = DateTime.add(nudge.occurred_at, 1, :second)

    Enum.any?(blocks, fn block ->
      flags = student_block_flags(block, nudge.account_id, index, after_at)
      reason in flags.slacking_flags
    end)
  end

  defp radar_blocks(index, nil), do: index.blocks_by_section |> Map.values() |> List.flatten()
  defp radar_blocks(index, section_id), do: Map.get(index.blocks_by_section, section_id, [])

  defp student_radar_row(account_id, team_id, blocks, index) do
    flagged_blocks =
      blocks
      |> Enum.map(&student_block_flags(&1, account_id, index))
      |> Enum.filter(&(&1.flags != []))

    slacking_index = flagged_blocks |> Enum.map(& &1.slacking_count) |> Enum.sum()
    struggling_index = flagged_blocks |> Enum.map(& &1.struggling_count) |> Enum.sum()
    config = engagement_config()

    status =
      cond do
        slacking_index >= Keyword.get(config, :student_radar_slacking_threshold, 2) -> :red
        struggling_index >= Keyword.get(config, :student_radar_struggling_threshold, 2) -> :yellow
        true -> :green
      end

    %{
      account_id: account_id,
      progress_percent: progress_percent(account_id, team_id, blocks),
      slacking_index: slacking_index,
      struggling_index: struggling_index,
      status: status,
      flagged_blocks: flagged_blocks
    }
  end

  defp student_block_flags(block, account_id, index, since_override \\ nil) do
    section = Map.fetch!(index.section_by_id, block.section_id)
    section_blocks = Map.fetch!(index.blocks_by_section, block.section_id)
    resolved_rule = Map.fetch!(index.resolved_rule_by_block_id, block.id)

    block_events =
      index.events_by_block
      |> Map.get(block.id, [])
      |> filter_by_account(account_id)
      |> filter_since(since_override)

    section_events =
      index.events_by_section
      |> Map.get(block.section_id, [])
      |> filter_by_account(account_id)
      |> filter_since(since_override)

    metrics =
      compute_block_metrics(
        block,
        section,
        section_blocks,
        block_events,
        section_events,
        resolved_rule
      )

    flags = flag_concerns(metrics)

    %{
      block_id: block.id,
      flags: flags.slacking ++ flags.struggling,
      slacking_flags: flags.slacking,
      struggling_flags: flags.struggling,
      slacking_count: length(flags.slacking),
      struggling_count: length(flags.struggling)
    }
  end

  # Whole-course fact, not a windowed behavior - reuses the same
  # `Athena.Learning.completed_block_ids/3` the Player's own waterline
  # already relies on, one section at a time (the course tree has no flat
  # "all blocks" progress query). `team_id` (from `team_scope_id/1`) is
  # `nil` for academic cohorts (individual completion records) and the
  # cohort id itself for `:team` cohorts, matching the shared completion
  # records `Athena.Learning.Progress.mark_completed/3` writes.
  defp progress_percent(_account_id, _team_id, []), do: 0.0

  defp progress_percent(account_id, team_id, blocks) do
    block_ids = MapSet.new(blocks, & &1.id)

    completed_count =
      blocks
      |> Enum.map(& &1.section_id)
      |> Enum.uniq()
      |> Enum.flat_map(&Learning.completed_block_ids(account_id, &1, team_id))
      |> Enum.filter(&MapSet.member?(block_ids, &1))
      |> Enum.uniq()
      |> length()

    completed_count / MapSet.size(block_ids) * 100
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
    days = Keyword.get(engagement_config(), :student_radar_default_window_days, 7)
    DateTime.add(DateTime.utc_now(), -days * 86_400, :second)
  end

  # Per-block-type dispatch

  defp compute_block_metrics(
         block,
         _section,
         section_blocks,
         block_events,
         section_events,
         resolved_rule
       ) do
    type_metrics = type_metrics_for(block.type, block_events)
    shared = shared_metrics(block_events, resolved_rule)
    backtrack = backtrack_count(block, section_blocks, section_events)

    type_metrics
    |> Map.merge(shared)
    |> Map.put(:backtrack_count, backtrack)
    |> Map.put(:backtrack_rate, rate(backtrack, shared.students_observed))
    |> Map.put(:hesitation_rate, hesitating_students_rate(block_events, shared.students_observed))
  end

  # One function clause per block type (rather than a `case`) keeps each
  # branch's complexity trivial - a `case` with this many arms in one
  # function body is exactly what trips Credo's cyclomatic-complexity check.
  defp type_metrics_for(:text, events), do: text_metrics(events)
  defp type_metrics_for(:video, events), do: video_metrics(events)
  defp type_metrics_for(:quiz_question, events), do: quiz_question_metrics(events)
  defp type_metrics_for(:quiz_exam, events), do: exam_metrics(events)
  defp type_metrics_for(:ticket_exam, events), do: exam_metrics(events)
  defp type_metrics_for(:code, events), do: code_metrics(events)
  defp type_metrics_for(:attachment, events), do: attachment_metrics(events)
  defp type_metrics_for(:image, events), do: image_metrics(events)
  defp type_metrics_for(:file_assignment, _events), do: %{}

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
  @spec flag_concerns(map()) :: %{content: [atom()], slacking: [atom()], struggling: [atom()]}
  def flag_concerns(metrics) do
    config = engagement_config()

    %{
      content: content_flags(metrics, config),
      slacking: slacking_flags(metrics, config),
      struggling: struggling_flags(metrics, config)
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
    |> add_if(
      metrics[:dwell_ratio],
      &(&1 < Keyword.get(config, :concern_dwell_ratio_threshold, 0.5)),
      :fast_dwell
    )
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
    |> add_if(
      metrics[:dwell_ratio],
      &(&1 > Keyword.get(config, :slow_dwell_ratio_threshold, 2.0)),
      :slow_dwell
    )
    |> add_if(metrics[:answer_change_count], &(&1 > 0), :hesitation)
    |> add_if(metrics[:backtrack_count], &(&1 > 0), :backtracked)
    |> add_if_true(metrics[:panic_debugging?] == true, :panic_debugging)
  end

  defp add_if(flags, nil, _condition?, _flag), do: flags
  defp add_if(flags, value, condition?, flag), do: add_if_true(flags, condition?.(value), flag)

  defp add_if_true(flags, true, flag), do: [flag | flags]
  defp add_if_true(flags, _falsy, _flag), do: flags

  defp rate(_count, 0), do: nil
  defp rate(count, total), do: count / total

  defp hesitating_students_rate(_events, 0), do: nil

  defp hesitating_students_rate(events, students_observed) do
    events
    |> distinct_accounts(&(&1.event_type == :answer_changed))
    |> MapSet.size()
    |> Kernel./(students_observed)
  end

  defp text_metrics(events) do
    %{avg_scroll_depth_percent: avg_scroll_depth(events)}
  end

  defp video_metrics(events) do
    %{
      play_count: Enum.count(events, &(&1.event_type == :video_play)),
      pause_count: Enum.count(events, &(&1.event_type == :video_pause)),
      seek_count: Enum.count(events, &(&1.event_type == :video_seek)),
      completion_count: Enum.count(events, &(&1.event_type == :video_ended)),
      skip_ratio: avg_video_skip_ratio(events)
    }
  end

  # Average, across sessions that finished the video, of how much of it was
  # skipped over via forward seeks - independent of whether nudges were
  # enabled for the cohort (unlike the Player's own in-the-moment nudge
  # decision, this reads straight from `video_seek`/`video_ended`, which are
  # always collected regardless of `cohort.nudges_enabled`).
  defp avg_video_skip_ratio(events) do
    events
    |> Enum.group_by(& &1.session_id)
    |> Enum.map(fn {_session_id, session_events} ->
      duration =
        session_events
        |> Enum.find(&(&1.event_type == :video_ended))
        |> case do
          %{payload: %{"duration" => duration}} -> duration
          _ -> nil
        end

      forward_skip =
        session_events
        |> Enum.filter(&(&1.event_type == :video_seek))
        |> Enum.map(fn e -> max((e.payload["to_sec"] || 0) - (e.payload["from_sec"] || 0), 0) end)
        |> Enum.sum()

      if is_number(duration) and duration > 0, do: forward_skip / duration, else: nil
    end)
    |> Enum.reject(&is_nil/1)
    |> avg()
  end

  defp quiz_question_metrics(events) do
    %{
      paste_ratio: avg_paste_ratio(events),
      answer_change_count: Enum.count(events, &(&1.event_type == :answer_changed))
    }
  end

  defp exam_metrics(events) do
    %{focus_loss_count: Enum.count(events, &(&1.event_type == :tab_hidden))}
  end

  defp code_metrics(events) do
    run_attempt_count = Enum.count(events, &(&1.event_type == :code_run_attempt))

    %{
      paste_ratio: avg_paste_ratio(events),
      run_attempt_count: run_attempt_count,
      debug_cycle_present?: run_attempt_count > 0,
      panic_debugging?: panic_debugging?(events)
    }
  end

  defp attachment_metrics(events) do
    %{
      open_count: Enum.count(events, &(&1.event_type == :attachment_open)),
      unique_openers:
        distinct_accounts(events, &(&1.event_type == :attachment_open)) |> MapSet.size()
    }
  end

  defp image_metrics(events) do
    %{zoom_count: Enum.count(events, &(&1.event_type == :image_zoom))}
  end

  defp shared_metrics(events, resolved_rule) do
    dwells = events |> Events.pair_viewport_dwells() |> Enum.map(&elem(&1, 2))

    %{
      sample_size: length(dwells),
      avg_dwell_seconds: avg(dwells),
      dwell_ratio: dwell_ratio(dwells, resolved_rule[:expected_seconds]),
      students_observed: distinct_accounts(events, fn _ -> true end) |> MapSet.size(),
      tab_hidden_count: Enum.count(events, &(&1.event_type == :tab_hidden)),
      avg_time_to_first_action: avg_time_to_first_action(events),
      offtask_ratio: offtask_ratio(events)
    }
  end

  # Share of the raw wall-clock time on this block that the student spent
  # tabbed away entirely (Off-Task Behavior) - out of `[0, 1]`, `nil` when
  # the block was never actually opened at all (nothing to divide by).
  defp offtask_ratio(events) do
    offtask_seconds =
      events
      |> Enum.filter(&(&1.event_type == :tab_visible))
      |> Enum.map(&((&1.payload["duration_ms"] || 0) / 1000))
      |> Enum.sum()

    total_seconds = events |> Events.raw_viewport_window_seconds() |> Enum.sum()

    if total_seconds > 0, do: min(offtask_seconds / total_seconds, 1.0), else: nil
  end

  # Time To First Action (TTFA): how long after entering the block did the
  # student do something (first code keystroke, first quiz answer saved) -
  # a quick TTFA is diving straight in, a long one is hesitation/avoidance
  # before starting. `first_interaction` is emitted once per (block,
  # session) by the Player, so there's at most one pair per session here.
  defp avg_time_to_first_action(events) do
    events
    |> Enum.group_by(& &1.session_id)
    |> Enum.map(fn {_session_id, session_events} ->
      sorted = Enum.sort_by(session_events, & &1.occurred_at, DateTime)
      enter = Enum.find(sorted, &(&1.event_type == :viewport_enter))
      first_action = Enum.find(sorted, &(&1.event_type == :first_interaction))

      if enter && first_action do
        max(DateTime.diff(first_action.occurred_at, enter.occurred_at, :second), 0)
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> avg()
  end

  # The flagship "went back to earlier content" signal: for each session,
  # walk its `viewport_enter` events (restricted to this section's blocks,
  # in chronological order) and check whether the student had already
  # reached a later block (by `order`) before coming back to this one.
  defp backtrack_count(block, section_blocks, section_events) do
    order_by_id = Map.new(section_blocks, &{&1.id, &1.order})

    section_events
    |> Enum.filter(&(&1.event_type == :viewport_enter))
    |> Enum.group_by(& &1.session_id)
    |> Enum.count(fn {_session_id, session_events} ->
      session_events
      |> Enum.sort_by(& &1.occurred_at, DateTime)
      |> backtracked_to?(block.id, block.order, order_by_id)
    end)
  end

  defp backtracked_to?(sorted_events, target_block_id, target_order, order_by_id) do
    # `Enum.reduce_while/3` returns the final accumulator when it never halts -
    # here that accumulator doubles as "have we seen later content yet?", which
    # is not the same thing as "did we backtrack". Only an explicit `:halt`
    # means "yes"; anything else (including running out of events while
    # `seen_later?` happens to be `true`) must resolve to `false`.
    reduction = &backtrack_reduction(&1, &2, target_block_id, target_order, order_by_id)

    case Enum.reduce_while(sorted_events, false, reduction) do
      :backtracked -> true
      _ -> false
    end
  end

  defp backtrack_reduction(event, seen_later?, target_block_id, target_order, order_by_id) do
    cond do
      event.block_id == target_block_id and seen_later? -> {:halt, :backtracked}
      Map.get(order_by_id, event.block_id, target_order) > target_order -> {:cont, true}
      true -> {:cont, seen_later?}
    end
  end

  defp events_for_scope(section_blocks, scope) do
    section_blocks
    |> Enum.map(& &1.id)
    |> Events.list_events_for_scope(Map.get(scope, :cohort_id), Map.get(scope, :since))
    |> filter_by_account(Map.get(scope, :account_id))
  end

  defp filter_by_account(events, nil), do: events

  defp filter_by_account(events, account_id),
    do: Enum.filter(events, &(&1.account_id == account_id))

  defp distinct_accounts(events, filter_fun) do
    events |> Enum.filter(filter_fun) |> Enum.map(& &1.account_id) |> MapSet.new()
  end

  defp dwell_ratio(_dwells, nil), do: nil
  defp dwell_ratio([], _expected_seconds), do: nil

  defp dwell_ratio(dwells, expected_seconds) do
    avg(dwells) / expected_seconds
  end

  defp avg_scroll_depth(events) do
    events
    |> Enum.filter(&(&1.event_type == :scroll_milestone))
    |> Enum.group_by(& &1.session_id)
    |> Enum.map(fn {_session_id, session_events} ->
      session_events |> Enum.map(&(&1.payload["percent"] || 0)) |> Enum.max()
    end)
    |> avg()
  end

  defp avg_paste_ratio(events) do
    events
    |> Enum.filter(&(&1.event_type == :paste_detected))
    |> Enum.map(fn event ->
      pasted = event.payload["pasted_chars"] || 0
      total = event.payload["total_chars"] || 0
      if total > 0, do: pasted / total, else: nil
    end)
    |> Enum.reject(&is_nil/1)
    |> avg()
  end

  # Error Quotient / "panic debugging" (Educational Data Mining): a student
  # who fixes something and reruns a few minutes later is doing normal
  # metacognitive debugging; one who mashes "Run" every few seconds without
  # time to have actually changed anything meaningful is frustrated, not
  # careless - a signal to intervene, not a "gaming the system" flag. Counts
  # how many consecutive `code_run_attempt` gaps are shorter than
  # `panic_debug_gap_seconds`; three or more such gaps is the threshold.
  defp panic_debugging?(events) do
    gap_seconds = Keyword.get(engagement_config(), :panic_debug_gap_seconds, 10)
    min_bursts = Keyword.get(engagement_config(), :panic_debug_min_bursts, 3)

    fast_gap_count =
      events
      |> Enum.filter(&(&1.event_type == :code_run_attempt))
      |> Enum.sort_by(& &1.occurred_at, DateTime)
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.count(fn [a, b] ->
        DateTime.diff(b.occurred_at, a.occurred_at, :second) < gap_seconds
      end)

    fast_gap_count >= min_bursts
  end

  defp engagement_config, do: Application.get_env(:athena, Athena.Engagement, [])

  defp avg([]), do: nil
  defp avg(list), do: Enum.sum(list) / length(list)

  defp week_start(%{occurred_at: occurred_at}) do
    date = DateTime.to_date(occurred_at)
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
