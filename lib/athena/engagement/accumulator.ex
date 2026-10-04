defmodule Athena.Engagement.Accumulator do
  @moduledoc """
  The one place engagement metrics are *defined*.

  Raw events are folded into additive per-(student, block, day) counters -
  an "accumulator" - and every metric is derived from those counters
  (`to_metrics/3`). Because every field is a plain count or sum, any number
  of accumulators can be merged (`merge/2`) without losing anything: a
  student's week is the merge of their seven days, a cohort's view of a
  block is the merge of its students.

  That is what lets the dashboards read pre-aggregated daily rows
  (`Athena.Engagement.Rollups`) instead of scanning raw events, while still
  producing exactly the numbers a raw scan would: both paths go through
  `build/2` + `to_metrics/3`.

  Per-session measurements (dwell pairs, max scroll depth, video skip, time
  to first action, backtracking) are taken within a session's events *of
  one day*: a session running across midnight is measured as two. That is
  the one approximation daily buckets introduce.
  """

  alias Athena.Engagement.Events
  alias Athena.TimeZones

  @counts ~w(event_count enter_count interact_count dwell_n tab_hidden window_blur printscreen
             copy_attempt cut_attempt multi_tab play pause seek ended answer_changed run_attempt
             fast_run_gaps attachment_open image_zoom nudge_shown scroll_n paste_n skip_n ttfa_n
             backtracks)a

  @sums ~w(dwell_sum window_sum offtask_sum idle_sum scroll_sum paste_sum skip_sum ttfa_sum)a

  @fields @counts ++ @sums

  @interaction_types [:viewport_exit, :paste_detected, :video_play, :attachment_open, :image_zoom]

  @simple_counts %{
    viewport_enter: :enter_count,
    tab_hidden: :tab_hidden,
    window_blur: :window_blur,
    printscreen_attempt: :printscreen,
    copy_attempt: :copy_attempt,
    cut_attempt: :cut_attempt,
    multi_tab_detected: :multi_tab,
    video_play: :play,
    video_pause: :pause,
    video_seek: :seek,
    video_ended: :ended,
    answer_changed: :answer_changed,
    code_run_attempt: :run_attempt,
    attachment_open: :attachment_open,
    image_zoom: :image_zoom,
    nudge_shown: :nudge_shown
  }

  @type t :: %{atom() => number() | [non_neg_integer()]}

  @doc "Counter field names, in storage order (`Athena.Engagement.Rollup` columns)."
  @spec fields() :: [atom()]
  def fields, do: @fields

  @doc "An accumulator with nothing in it."
  @spec empty() :: t()
  def empty do
    @fields
    |> Map.new(&{&1, 0})
    |> Map.merge(Map.new(@sums, &{&1, 0.0}))
    |> Map.put(:hour_counts, List.duplicate(0, 24))
  end

  @doc """
  Folds raw events into `%{{account_id, block_id, day} => accumulator}`,
  `day` being the app-timezone date of each event.

  `block_positions` maps a block id to `{section_id, order}`; it is only
  needed for backtracking (returning to an earlier block of the same
  section within one session), and events on blocks missing from it simply
  don't contribute to that one counter.
  """
  @spec build([map()], %{binary() => {binary(), integer()}}) :: %{
          {binary(), binary(), Date.t()} => t()
        }
  def build(events, block_positions \\ %{}) do
    localized = Enum.map(events, &localize/1)

    buckets =
      localized
      |> Enum.group_by(fn {event, day, _hour} -> {event.account_id, event.block_id, day} end)
      |> Map.new(fn {key, bucket} -> {key, bucket_counters(bucket)} end)

    localized
    |> backtracks(block_positions)
    |> Enum.reduce(buckets, fn {key, count}, acc ->
      Map.update(
        acc,
        key,
        %{empty() | backtracks: count},
        &%{&1 | backtracks: &1.backtracks + count}
      )
    end)
  end

  @doc "Adds two accumulators field by field."
  @spec merge(t(), t()) :: t()
  def merge(a, b) do
    a
    |> Map.new(fn
      {:hour_counts, hours} -> {:hour_counts, sum_hours(hours, b.hour_counts)}
      {field, value} -> {field, value + Map.get(b, field, 0)}
    end)
  end

  @doc "Merges a list of accumulators (`empty/0` for none)."
  @spec merge_all([t()]) :: t()
  def merge_all(accumulators), do: Enum.reduce(accumulators, empty(), &merge/2)

  @doc """
  Collapses `%{{account_id, block_id, day} => acc}` (or any map whose keys
  start with `{account_id, block_id, ...}`) into
  `%{{account_id, block_id} => acc}` - a student's whole window per block.
  """
  @spec by_account_block(map()) :: %{{binary(), binary()} => t()}
  def by_account_block(buckets) do
    Enum.reduce(buckets, %{}, fn {{account_id, block_id, _day}, acc}, out ->
      Map.update(out, {account_id, block_id}, acc, &merge(&1, acc))
    end)
  end

  @doc """
  Metrics for one student's accumulator on one block, keyed exactly like
  `Athena.Engagement.Metrics.get_metrics/1` always returned them.
  """
  @spec to_metrics(t(), atom(), map()) :: map()
  def to_metrics(acc, block_type, resolved_rule) do
    to_metrics(acc, block_type, resolved_rule, observed(acc))
  end

  @doc """
  Metrics for several students' accumulators on one block (a cohort-wide
  view): counters are summed, and the per-student shares
  (`students_observed`, `hesitation_rate`, `unique_openers`) are counted
  across the given students.
  """
  @spec to_cohort_metrics([t()], atom(), map()) :: map()
  def to_cohort_metrics(accumulators, block_type, resolved_rule) do
    observed =
      Enum.reduce(accumulators, %{students: 0, hesitating: 0, openers: 0}, fn acc, totals ->
        Map.merge(totals, observed(acc), fn _key, a, b -> a + b end)
      end)

    to_metrics(merge_all(accumulators), block_type, resolved_rule, observed)
  end

  defp observed(acc) do
    %{
      students: if(acc.event_count > 0, do: 1, else: 0),
      hesitating: if(acc.answer_changed > 0, do: 1, else: 0),
      openers: if(acc.attachment_open > 0, do: 1, else: 0)
    }
  end

  defp to_metrics(acc, block_type, resolved_rule, observed) do
    avg_dwell = avg(acc.dwell_sum, acc.dwell_n)

    shared = %{
      sample_size: acc.dwell_n,
      avg_dwell_seconds: avg_dwell,
      dwell_ratio: dwell_ratio(avg_dwell, resolved_rule[:expected_seconds]),
      students_observed: observed.students,
      tab_hidden_count: acc.tab_hidden,
      avg_time_to_first_action: avg(acc.ttfa_sum, acc.ttfa_n),
      offtask_ratio:
        if(acc.window_sum > 0, do: min(acc.offtask_sum / acc.window_sum, 1.0), else: nil)
    }

    block_type
    |> type_metrics(acc, observed)
    |> Map.merge(shared)
    |> Map.put(:backtrack_count, acc.backtracks)
    |> Map.put(:backtrack_rate, rate(acc.backtracks, observed.students))
    |> Map.put(:hesitation_rate, rate(observed.hesitating, observed.students))
  end

  # One clause per block type - same split as the metric catalog itself.
  defp type_metrics(:text, acc, _observed),
    do: %{avg_scroll_depth_percent: avg(acc.scroll_sum, acc.scroll_n)}

  defp type_metrics(:video, acc, _observed) do
    %{
      play_count: acc.play,
      pause_count: acc.pause,
      seek_count: acc.seek,
      completion_count: acc.ended,
      skip_ratio: avg(acc.skip_sum, acc.skip_n)
    }
  end

  defp type_metrics(:quiz_question, acc, _observed) do
    %{paste_ratio: avg(acc.paste_sum, acc.paste_n), answer_change_count: acc.answer_changed}
  end

  defp type_metrics(type, acc, _observed) when type in [:quiz_exam, :ticket_exam] do
    %{
      focus_loss_count: acc.tab_hidden,
      focus_loss_seconds: acc.offtask_sum,
      window_blur_count: acc.window_blur,
      printscreen_count: acc.printscreen,
      copy_attempt_count: acc.copy_attempt,
      cut_attempt_count: acc.cut_attempt,
      multi_tab_count: acc.multi_tab,
      idle_seconds_total: acc.idle_sum,
      exam_paste_ratio: avg(acc.paste_sum, acc.paste_n),
      exam_answer_change_count: acc.answer_changed,
      exam_run_attempt_count: acc.run_attempt,
      exam_panic_debugging?: panic?(acc)
    }
  end

  defp type_metrics(:code, acc, _observed) do
    %{
      paste_ratio: avg(acc.paste_sum, acc.paste_n),
      run_attempt_count: acc.run_attempt,
      debug_cycle_present?: acc.run_attempt > 0,
      panic_debugging?: panic?(acc)
    }
  end

  defp type_metrics(:attachment, acc, observed),
    do: %{open_count: acc.attachment_open, unique_openers: observed.openers}

  defp type_metrics(:image, acc, _observed), do: %{zoom_count: acc.image_zoom}
  defp type_metrics(_type, _acc, _observed), do: %{}

  # Error Quotient / "panic debugging": at least `panic_debug_min_bursts`
  # consecutive runs fired less than `panic_debug_gap_seconds` apart.
  defp panic?(acc),
    do: acc.fast_run_gaps >= Keyword.get(config(), :panic_debug_min_bursts, 3)

  # Folding one (student, block, day) bucket

  defp bucket_counters(bucket) do
    events = Enum.map(bucket, &elem(&1, 0))
    sessions = Enum.group_by(events, & &1.session_id)
    dwells = events |> Events.pair_viewport_dwells() |> Enum.map(&elem(&1, 2))
    {paste_sum, paste_n} = events |> paste_ratios() |> sum_and_count()
    {scroll_sum, scroll_n} = sessions |> Enum.flat_map(&session_max_scroll/1) |> sum_and_count()
    {skip_sum, skip_n} = sessions |> Enum.flat_map(&session_skip_ratio/1) |> sum_and_count()
    {ttfa_sum, ttfa_n} = sessions |> Enum.flat_map(&session_ttfa/1) |> sum_and_count()

    counts =
      Enum.reduce(events, %{}, fn event, acc ->
        case Map.fetch(@simple_counts, event.event_type) do
          {:ok, field} -> Map.update(acc, field, 1, &(&1 + 1))
          :error -> acc
        end
      end)

    empty()
    |> Map.merge(counts)
    |> Map.merge(%{
      event_count: length(events),
      interact_count: Enum.count(events, &(&1.event_type in @interaction_types)),
      dwell_n: length(dwells),
      dwell_sum: Enum.sum(dwells) * 1.0,
      window_sum: events |> Events.raw_viewport_window_seconds() |> Enum.sum() |> Kernel.*(1.0),
      offtask_sum: duration_seconds(events, :tab_visible),
      idle_sum: duration_seconds(events, :idle_end),
      paste_sum: paste_sum,
      paste_n: paste_n,
      scroll_sum: scroll_sum,
      scroll_n: scroll_n,
      skip_sum: skip_sum,
      skip_n: skip_n,
      ttfa_sum: ttfa_sum,
      ttfa_n: ttfa_n,
      fast_run_gaps: fast_run_gaps(events),
      hour_counts: hour_counts(bucket)
    })
  end

  defp localize(event) do
    local = TimeZones.to_app_zone(event.occurred_at)
    {event, DateTime.to_date(local), local.hour}
  end

  defp hour_counts(bucket) do
    counts = Enum.frequencies_by(bucket, &elem(&1, 2))
    Enum.map(0..23, &Map.get(counts, &1, 0))
  end

  defp duration_seconds(events, event_type) do
    events
    |> Enum.filter(&(&1.event_type == event_type))
    |> Enum.map(&((&1.payload["duration_ms"] || 0) / 1000))
    |> Enum.sum()
    |> Kernel.*(1.0)
  end

  defp paste_ratios(events) do
    for %{event_type: :paste_detected, payload: payload} <- events,
        total = payload["total_chars"] || 0,
        total > 0,
        do: (payload["pasted_chars"] || 0) / total
  end

  defp session_max_scroll({_session_id, events}) do
    case for(%{event_type: :scroll_milestone, payload: p} <- events, do: p["percent"] || 0) do
      [] -> []
      percents -> [Enum.max(percents)]
    end
  end

  # How much of the video was jumped over with forward seeks, for sessions
  # that reached the end (the only ones that know the video's duration).
  defp session_skip_ratio({_session_id, events}) do
    duration =
      Enum.find_value(events, fn
        %{event_type: :video_ended, payload: %{"duration" => duration}} -> duration
        _ -> nil
      end)

    forward_skip =
      for %{event_type: :video_seek, payload: p} <- events,
          reduce: 0 do
        acc -> acc + max((p["to_sec"] || 0) - (p["from_sec"] || 0), 0)
      end

    if is_number(duration) and duration > 0, do: [forward_skip / duration], else: []
  end

  # Time To First Action: from entering the block to the first interaction.
  defp session_ttfa({_session_id, events}) do
    sorted = Enum.sort_by(events, & &1.occurred_at, DateTime)
    enter = Enum.find(sorted, &(&1.event_type == :viewport_enter))
    first_action = Enum.find(sorted, &(&1.event_type == :first_interaction))

    if enter && first_action,
      do: [max(DateTime.diff(first_action.occurred_at, enter.occurred_at, :second), 0)],
      else: []
  end

  defp fast_run_gaps(events) do
    gap_seconds = Keyword.get(config(), :panic_debug_gap_seconds, 10)

    events
    |> Enum.filter(&(&1.event_type == :code_run_attempt))
    |> Enum.sort_by(& &1.occurred_at, DateTime)
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.count(fn [a, b] ->
      DateTime.diff(b.occurred_at, a.occurred_at, :second) < gap_seconds
    end)
  end

  # The flagship "went back to earlier content" signal: within one session
  # (and one day), entering a block after a later block of the same section
  # was already reached counts once for that block.
  defp backtracks(localized, block_positions) do
    localized
    |> Enum.filter(fn {event, _day, _hour} ->
      event.event_type == :viewport_enter and Map.has_key?(block_positions, event.block_id)
    end)
    |> Enum.group_by(fn {event, day, _hour} ->
      {section_id, _order} = Map.fetch!(block_positions, event.block_id)
      {event.session_id, section_id, day}
    end)
    |> Enum.flat_map(fn {{_session, _section, day}, enters} ->
      enters
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort_by(& &1.occurred_at, DateTime)
      |> session_backtracks(block_positions)
      |> Enum.map(fn {account_id, block_id} -> {account_id, block_id, day} end)
    end)
    |> Enum.frequencies()
  end

  defp session_backtracks(sorted_enters, block_positions) do
    {found, _max_order} =
      Enum.reduce(sorted_enters, {MapSet.new(), nil}, fn event, {found, max_order} ->
        {_section, order} = Map.fetch!(block_positions, event.block_id)

        found =
          if max_order && max_order > order,
            do: MapSet.put(found, {event.account_id, event.block_id}),
            else: found

        {found, if(max_order, do: max(max_order, order), else: order)}
      end)

    MapSet.to_list(found)
  end

  defp sum_hours(a, b), do: Enum.zip_with(a, b, &(&1 + &2))

  defp sum_and_count(values), do: {Enum.sum(values) * 1.0, length(values)}

  defp avg(_sum, 0), do: nil
  defp avg(sum, count), do: sum / count

  defp dwell_ratio(nil, _expected), do: nil
  defp dwell_ratio(_avg, nil), do: nil
  defp dwell_ratio(avg, expected), do: avg / expected

  defp rate(_count, 0), do: nil
  defp rate(count, total), do: count / total

  defp config, do: Application.get_env(:athena, Athena.Engagement, [])
end
