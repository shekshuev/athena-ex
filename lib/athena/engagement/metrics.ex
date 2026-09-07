defmodule Athena.Engagement.Metrics do
  @moduledoc """
  Turns raw `Athena.Engagement.Event` rows into the metric catalog: per-block
  numbers a teacher or researcher can actually read, computed on demand
  (`group_by`-style, no cache/materialized table - same style as
  `Athena.Learning.Submissions.get_team_leaderboard/1`).

  `get_metrics/1` is the one entry point meant for a future dashboard (a
  course-tree node plus an optional cohort/student filter); `funnel/2`,
  `correlate/2`, and `time_series/3` are the other four "Методы анализа"
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
  alias Athena.Engagement.Events
  alias Athena.Learning

  @doc """
  Metrics for a course-tree node, optionally narrowed to one cohort and/or
  one student - the shape a future "pick a node, filter above it" dashboard
  needs. `resource_type: :block` returns one metrics map; `:section` returns
  `%{block_id => metrics}` for every block directly inside it.
  """
  @spec get_metrics(%{
          required(:resource_type) => :block | :section,
          required(:resource_id) => binary(),
          optional(:cohort_id) => binary() | nil,
          optional(:account_id) => binary() | nil
        }) :: map()
  def get_metrics(%{resource_type: :block, resource_id: block_id} = scope) do
    with {:ok, block} <- Content.get_block(block_id),
         {:ok, section} <- Content.get_section(block.section_id) do
      section_blocks =
        section.id |> Content.list_blocks_by_section(:all) |> Enum.sort_by(& &1.order)

      compute_block_metrics(block, section_blocks, scope)
    else
      _ -> %{}
    end
  end

  def get_metrics(%{resource_type: :section, resource_id: section_id} = scope) do
    section_blocks =
      section_id |> Content.list_blocks_by_section(:all) |> Enum.sort_by(& &1.order)

    Map.new(section_blocks, fn block ->
      {block.id, compute_block_metrics(block, section_blocks, scope)}
    end)
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
  ("межгрупповое сравнение когорт") needs for a statistics package (R/
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

  # Per-block-type dispatch

  defp compute_block_metrics(block, section_blocks, scope) do
    events = fetch_events(block.id, scope)

    type_metrics =
      case block.type do
        :text -> text_metrics(block, events)
        :video -> video_metrics(events)
        :quiz_question -> quiz_question_metrics(events)
        :quiz_exam -> exam_metrics(events)
        :ticket_exam -> exam_metrics(events)
        :code -> code_metrics(events)
        :attachment -> attachment_metrics(events)
        :image -> image_metrics(events)
        :file_assignment -> %{}
      end

    type_metrics
    |> Map.merge(shared_metrics(events))
    |> Map.put(
      :backtrack_count,
      backtrack_count(block, section_blocks, events_for_scope(section_blocks, scope))
    )
  end

  defp text_metrics(block, events) do
    expected_seconds =
      get_in(block, [Access.key(:engagement_rule), Access.key(:expected_seconds)])

    dwells = events |> Events.pair_viewport_dwells() |> Enum.map(&elem(&1, 2))

    %{
      dwell_ratio: dwell_ratio(dwells, expected_seconds),
      avg_scroll_depth_percent: avg_scroll_depth(events)
    }
  end

  defp video_metrics(events) do
    %{
      play_count: Enum.count(events, &(&1.event_type == :video_play)),
      pause_count: Enum.count(events, &(&1.event_type == :video_pause)),
      seek_count: Enum.count(events, &(&1.event_type == :video_seek)),
      completion_count: Enum.count(events, &(&1.event_type == :video_ended))
    }
  end

  defp quiz_question_metrics(events) do
    %{paste_ratio: avg_paste_ratio(events)}
  end

  defp exam_metrics(events) do
    %{focus_loss_count: Enum.count(events, &(&1.event_type == :tab_hidden))}
  end

  defp code_metrics(events) do
    %{paste_ratio: avg_paste_ratio(events)}
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

  defp shared_metrics(events) do
    dwells = events |> Events.pair_viewport_dwells() |> Enum.map(&elem(&1, 2))

    %{
      sample_size: length(dwells),
      avg_dwell_seconds: avg(dwells),
      students_observed: distinct_accounts(events, fn _ -> true end) |> MapSet.size(),
      tab_hidden_count: Enum.count(events, &(&1.event_type == :tab_hidden))
    }
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
    case Enum.reduce_while(sorted_events, false, fn event, seen_later? ->
           cond do
             event.block_id == target_block_id and seen_later? -> {:halt, :backtracked}
             Map.get(order_by_id, event.block_id, target_order) > target_order -> {:cont, true}
             true -> {:cont, seen_later?}
           end
         end) do
      :backtracked -> true
      _ -> false
    end
  end

  defp events_for_scope(section_blocks, scope) do
    section_blocks
    |> Enum.map(& &1.id)
    |> Events.list_events_for_scope(Map.get(scope, :cohort_id))
    |> filter_by_account(Map.get(scope, :account_id))
  end

  defp fetch_events(block_id, scope) do
    [block_id]
    |> Events.list_events_for_scope(Map.get(scope, :cohort_id))
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
