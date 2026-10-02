defmodule Athena.Engagement.Proctoring do
  @moduledoc """
  Turns a `Athena.Engagement.ProctoringMonitor` reading into the
  `risk_level`/`points`/`signals` fields persisted on `Submission.content`,
  and the summary/detail read back out of them.

  Every observed signal is worth **points**; the level is just where the
  total lands (`yellow_points` / `red_points` in config). Three kinds of
  signal feed it:

  - **Direct violations** (`printscreen_attempt`, `copy_attempt`,
    `cut_attempt`, `multi_tab_detected`, a single large paste, a bulk
    insert that bypassed typing) - counted as-is, 2 points each. There is
    no legitimate reason for any of these during a locked-down question
    view, so a raw count is already meaningful on its own.
  - **Absence and connection** - time spent away from the exam (tab hidden,
    window blurred, fullscreen exited; overlapping absences merged), a
    stretch where the telemetry channel went quiet or the browser went
    offline, a suspected split screen. There is deliberately no
    teacher-set "allowed N times": an absence is judged by how often and
    how long, not against a number someone picked.
  - **Behavioral outliers** (focus-loss rate, answer-change rate, paste
    ratio, right-click rate, time with the mouse outside the window) - a raw
    count here means nothing by itself (an anxious student revising an
    answer 50 times looks identical, by the numbers, to one who's
    cheating), so a rate is judged against the *others sitting this same
    exam*: it counts when it is clearly above their typical value (see
    `exceeds_group?/3`). That works from a group of three; the smaller the
    group, the less the group alone is trusted and the more an absolute
    limit backs it up (see `group_threshold/3`). With nobody to compare
    against there is only the absolute limit. Finished students stay in
    the comparison, so the group does not shrink as people hand in.

  Silence and offline gaps are sticky for the whole attempt: the longest
  gap is what counts, it never decays. A teacher can review and dismiss a
  verdict (`content["proctoring_review"]`) but the recorded signals stay.

  Deliberately generic over any submission - a submission with no
  `risk_level` key in its content (i.e. everything except
  `quiz_exam`/`ticket_exam`) is simply "no data", not an error, so callers
  can call `summary/1`/`detail/1` on any submission's content without
  special-casing the block type.
  """

  alias Athena.Engagement.{ExamIntegrityStats, ProctoringMonitor}

  @type risk_level :: :green | :yellow | :red

  # {metric, points when flagged, per-minute?}. Per-minute rates are
  # withheld until the attempt is old enough for them to be stable.
  @relative_metrics [
    {:tab_hidden_per_minute, 1, true},
    {:paste_ratio, 2, false},
    {:answer_changed_per_minute, 1, true},
    {:right_click_per_minute, 1, true},
    {:mouse_away_seconds_per_minute, 1, true}
  ]

  @hard_events [
    :printscreen_attempt,
    :copy_attempt,
    :cut_attempt,
    :multi_tab_detected,
    :large_paste,
    :bulk_insert
  ]

  @default_floors %{
    tab_hidden_per_minute: 0.2,
    paste_ratio: 0.2,
    answer_changed_per_minute: 0.5,
    right_click_per_minute: 0.2,
    mouse_away_seconds_per_minute: 3.0
  }

  # Fewest events (seconds, for mouse time) a per-minute rate must be built
  # from before it can count: a floor on the *rate* alone lets one stray
  # event through on a short attempt (1 event in 5 min is 0.2/min).
  @default_min_totals %{
    tab_hidden_per_minute: 3,
    answer_changed_per_minute: 5,
    right_click_per_minute: 2,
    mouse_away_seconds_per_minute: 20
  }

  @default_fallbacks %{
    tab_hidden_per_minute: 1.0,
    paste_ratio: 0.8,
    answer_changed_per_minute: 3.0,
    right_click_per_minute: 1.0,
    mouse_away_seconds_per_minute: 15.0
  }

  @doc """
  Every rate this module compares against peers, for display - including
  per-minute rates of an attempt that is still too young to evaluate.
  """
  @spec all_rates(map()) :: map()
  def all_rates(%{counts: counts, elapsed_minutes: elapsed} = reading) do
    %{
      # Distinct (merged) absences, not raw tab_hidden + window_blur events:
      # one Alt-Tab fires both and must count once.
      tab_hidden_per_minute: Map.get(reading, :away_count, 0) / elapsed,
      answer_changed_per_minute: count(counts, :answer_changed) / elapsed,
      paste_ratio: Map.get(counts, :paste_ratio, 0.0),
      right_click_per_minute: count(counts, :right_click_attempt) / elapsed,
      mouse_away_seconds_per_minute: Map.get(reading, :mouse_away_seconds, 0) / elapsed
    }
  end

  @doc """
  The subset of `all_rates/1` stable enough to judge: per-minute rates are
  dropped while the attempt is younger than `min_minutes_for_rates`. This
  is also exactly what `ProctoringMonitor` reports to the cohort baseline,
  so the comparison is always apples-to-apples.
  """
  @spec rates(map()) :: map()
  def rates(%{elapsed_minutes: elapsed} = reading) do
    all = all_rates(reading)

    if elapsed >= thresholds().min_minutes_for_rates do
      all
    else
      Map.take(all, for({metric, _points, false} <- @relative_metrics, do: metric))
    end
  end

  @doc """
  Full evaluation of an exam attempt at its current reading (from
  `ProctoringMonitor.snapshot/1` or `finalize/1`). Read-only - never
  mutates `ExamIntegrityStats`. Safe to call repeatedly on an in-progress
  attempt (the live risk indicator) as well as once at finalize time.
  """
  @spec evaluate(ProctoringMonitor.reading() | map(), binary() | nil, binary(), keyword()) ::
          map()
  def evaluate(%{counts: counts} = reading, cohort_id, block_id, opts \\ []) do
    t = thresholds()

    silence_seconds =
      max(Map.get(reading, :max_silence_seconds, 0), Map.get(reading, :max_offline_seconds, 0))

    eligible = rates(reading)
    all = all_rates(reading)

    # The student's own value never counts as part of "the others".
    baselines = ExamIntegrityStats.baselines(cohort_id, block_id, opts[:submission_id])
    relative = relative_signals(eligible, baselines, reading.elapsed_minutes, counts, t)

    signals =
      hard_signals(counts) ++
        away_signals(reading, t) ++
        silence_signals(silence_seconds, t) ++
        split_screen_signals(counts) ++
        typing_signals(Map.get(reading, :typing, %{}), t) ++
        relative

    points = signals |> Enum.map(& &1["points"]) |> Enum.sum()

    outlier_metrics = Map.new(relative, fn signal -> {signal["key"], signal["value"]} end)

    %{
      "hard_evidence_count" => Enum.sum(for event <- @hard_events, do: count(counts, event)),
      "outlier_metrics" => outlier_metrics,
      "risk_level" => points |> risk_level() |> Atom.to_string(),
      "points" => points,
      "signals" => signals,
      "event_counts" => stringify(Map.drop(counts, [:paste_ratio])),
      "rates" => stringify(all),
      "group_baselines" => group_baselines(all, baselines),
      "elapsed_minutes" => reading.elapsed_minutes,
      "heartbeat_silence_seconds" => silence_seconds,
      "away_incidents" => Map.get(reading, :away_incidents, 0),
      "away_total_seconds" => Map.get(reading, :away_total_seconds, 0),
      "mouse_away_seconds" => Map.get(reading, :mouse_away_seconds, 0),
      "max_paste_chars" => Map.get(reading, :max_paste_chars, 0),
      "typing" => typing_summary(Map.get(reading, :typing, %{})),
      "incidents" => Map.get(reading, :incidents, [])
    }
  end

  # What "typical" is for the others, per metric, for display next to the
  # student's own rate - whether or not it was flagged.
  defp group_baselines(rates, baselines) do
    for {metric, _value} <- rates, into: %{} do
      baseline = Map.get(baselines, metric, %{n: 0, median: 0.0})

      {to_string(metric),
       %{"peers" => baseline.n, "median" => Float.round(baseline.median * 1.0, 3)}}
    end
  end

  defp hard_signals(counts) do
    for event <- @hard_events, (n = count(counts, event)) > 0 do
      %{"key" => to_string(event), "points" => 2 * n, "value" => n, "basis" => "count"}
    end
  end

  # Merged absences, not a teacher-set allowance: one long absence or
  # several short ones both add up, and `away_red_*` says when it's enough
  # on its own for red.
  defp away_signals(reading, t) do
    incidents = Map.get(reading, :away_incidents, 0)
    total = Map.get(reading, :away_total_seconds, 0)

    cond do
      incidents >= t.away_red_incidents or total >= t.away_red_seconds ->
        [
          %{
            "key" => "away",
            "points" => t.red_points,
            "value" => total,
            "incidents" => incidents,
            "basis" => "duration"
          }
        ]

      incidents >= 1 ->
        [
          %{
            "key" => "away",
            "points" => t.yellow_points,
            "value" => total,
            "incidents" => incidents,
            "basis" => "duration"
          }
        ]

      true ->
        []
    end
  end

  defp silence_signals(seconds, t) do
    cond do
      seconds >= t.heartbeat_silence_red_threshold_seconds ->
        [
          %{
            "key" => "silence",
            "points" => t.red_points,
            "value" => seconds,
            "basis" => "duration"
          }
        ]

      seconds >= t.heartbeat_silence_yellow_threshold_seconds ->
        [
          %{
            "key" => "silence",
            "points" => t.yellow_points,
            "value" => seconds,
            "basis" => "duration"
          }
        ]

      true ->
        []
    end
  end

  defp split_screen_signals(counts) do
    case count(counts, :split_screen) do
      0 -> []
      1 -> [%{"key" => "split_screen", "points" => 1, "value" => 1, "basis" => "count"}]
      n -> [%{"key" => "split_screen", "points" => 2, "value" => n, "basis" => "count"}]
    end
  end

  defp typing_signals(typing, t) do
    keys = Map.get(typing, :keys, 0)
    typed = Map.get(typing, :chars_typed, 0)
    deleted = Map.get(typing, :chars_deleted, 0)

    machine =
      if keys >= t.machine_typing_min_keys and
           Map.get(typing, :dwell_sum, 0.0) / keys <= t.machine_typing_max_dwell_ms,
         do: [%{"key" => "machine_typing", "points" => 2, "value" => keys, "basis" => "pattern"}],
         else: []

    clean =
      if typed >= t.clean_typing_min_chars and
           deleted / typed < t.clean_typing_max_correction_ratio,
         do: [%{"key" => "clean_typing", "points" => 1, "value" => typed, "basis" => "pattern"}],
         else: []

    machine ++ clean
  end

  defp relative_signals(rates, baselines, elapsed, counts, t) do
    for {metric, points, per_minute} <- @relative_metrics,
        Map.has_key?(rates, metric),
        enough_events?(metric, rates[metric], per_minute, elapsed, t),
        not paste_already_counted?(metric, counts),
        signal = relative_signal(metric, points, rates[metric], Map.get(baselines, metric), t),
        do: signal
  end

  # A per-minute rate must rest on a minimum number of events (see
  # `@default_min_totals`); ratios have no such total.
  defp enough_events?(_metric, _value, false, _elapsed, _t), do: true

  defp enough_events?(metric, value, true, elapsed, t),
    do: value * elapsed >= t.min_totals[metric]

  # A single large paste already counts as a direct violation; letting it
  # also push the paste ratio over the line would charge the same event
  # twice.
  defp paste_already_counted?(:paste_ratio, counts), do: count(counts, :large_paste) > 0
  defp paste_already_counted?(_metric, _counts), do: false

  # Three ways a rate counts, strongest reason first:
  #
  #   1. It is at least `extreme_factor` times the absolute limit. No group
  #      can make that normal - if everybody does it, that is a finding too.
  #   2. There is a group to compare against (`min_baseline_peers` others)
  #      and the value clears the group's threshold.
  #   3. There is no usable group, and the value reaches the absolute limit.
  defp relative_signal(metric, points, value, baseline, t) do
    fallback = t.fallbacks[metric]
    peers = if baseline, do: baseline.n, else: 0

    cond do
      value >= fallback * t.extreme_factor ->
        signal(metric, points, value, "absolute", baseline, fallback)

      peers >= t.min_baseline_peers ->
        threshold = group_threshold(metric, baseline, t)
        if value >= threshold, do: signal(metric, points, value, "group", baseline, threshold)

      value >= fallback ->
        signal(metric, points, value, "absolute", baseline, fallback)

      true ->
        nil
    end
  end

  @doc """
  The value a rate must reach to stand out from the others, given their
  baseline (`%{n:, median:, spread:}`): the highest of

    * the metric's absolute floor - never flag a trivial amount;
    * `baseline_ratio` times the group's typical value, and the typical
      value plus `baseline_spread` times the group's spread - clearly above
      what the others do, however much they hesitate;
    * for a small group (fewer than `trusted_group_peers` others), a fixed
      share of the absolute limit. Two or three classmates are a weak
      witness of what is normal, so they can raise the bar but never lower
      it below that share.
  """
  @spec group_threshold(atom(), map(), map()) :: float()
  def group_threshold(metric, baseline, t) do
    candidates = [
      t.floors[metric],
      t.baseline_ratio * baseline.median,
      baseline.median + t.baseline_spread * baseline.spread
    ]

    candidates =
      if baseline.n < t.trusted_group_peers,
        do: [t.fallbacks[metric] * t.small_group_fallback_share | candidates],
        else: candidates

    Enum.max(candidates)
  end

  defp signal(metric, points, value, basis, baseline, threshold) do
    %{
      "key" => to_string(metric),
      "points" => points,
      "value" => value,
      "basis" => basis,
      "threshold" => threshold,
      "peers" => if(baseline, do: baseline.n, else: 0),
      "baseline" => if(baseline, do: baseline.median, else: nil)
    }
  end

  defp typing_summary(typing) do
    keys = Map.get(typing, :keys, 0)

    %{
      "keys" => keys,
      "avg_dwell_ms" =>
        if(keys > 0, do: Float.round(Map.get(typing, :dwell_sum, 0.0) / keys, 1), else: nil),
      "flight_cv" =>
        if(keys > 0, do: Float.round(Map.get(typing, :cv_sum, 0.0) / keys, 2), else: nil),
      "pauses" => Map.get(typing, :pauses, 0),
      "max_clean_run" => Map.get(typing, :max_clean_run, 0),
      "chars_typed" => Map.get(typing, :chars_typed, 0),
      "chars_deleted" => Map.get(typing, :chars_deleted, 0)
    }
  end

  defp count(counts, key), do: Map.get(counts, key, 0)
  defp stringify(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  @doc """
  The verdict for a points total. Points rather than "any flag turns it
  yellow" so that a pile of weak, unrelated signals can't add up to red by
  accident while one strong signal still can.
  """
  @spec risk_level(number()) :: risk_level()
  def risk_level(points) do
    t = thresholds()

    cond do
      points >= t.red_points -> :red
      points >= t.yellow_points -> :yellow
      true -> :green
    end
  end

  @doc """
  Every tunable threshold this module reads from config, for display in the
  methodology modal - keeps that copy from going stale if `config.exs`
  changes.
  """
  @spec thresholds() :: map()
  def thresholds do
    config = Application.get_env(:athena, Athena.Engagement, [])

    %{
      yellow_points: Keyword.get(config, :exam_risk_yellow_points, 2),
      red_points: Keyword.get(config, :exam_risk_red_points, 4),
      min_baseline_peers: Keyword.get(config, :exam_min_baseline_peers, 2),
      trusted_group_peers: Keyword.get(config, :exam_trusted_group_peers, 8),
      baseline_ratio: Keyword.get(config, :exam_baseline_ratio, 3),
      baseline_spread: Keyword.get(config, :exam_baseline_spread, 3),
      small_group_fallback_share: Keyword.get(config, :exam_small_group_fallback_share, 0.5),
      extreme_factor: Keyword.get(config, :exam_extreme_factor, 2),
      min_minutes_for_rates: Keyword.get(config, :exam_min_minutes_for_rates, 3),
      floors: Map.merge(@default_floors, Map.new(Keyword.get(config, :exam_metric_floors, %{}))),
      min_totals:
        Map.merge(@default_min_totals, Map.new(Keyword.get(config, :exam_metric_min_totals, %{}))),
      fallbacks:
        Map.merge(@default_fallbacks, Map.new(Keyword.get(config, :exam_metric_fallbacks, %{}))),
      large_paste_chars: Keyword.get(config, :exam_large_paste_chars, 150),
      away_incident_min_seconds: Keyword.get(config, :exam_away_incident_min_seconds, 10),
      away_red_incidents: Keyword.get(config, :exam_away_red_incidents, 3),
      away_red_seconds: Keyword.get(config, :exam_away_red_seconds, 60),
      heartbeat_silence_yellow_threshold_seconds:
        Keyword.get(config, :exam_heartbeat_silence_yellow_threshold_seconds, 45),
      heartbeat_silence_red_threshold_seconds:
        Keyword.get(config, :exam_heartbeat_silence_red_threshold_seconds, 120),
      machine_typing_min_keys: Keyword.get(config, :exam_machine_typing_min_keys, 50),
      machine_typing_max_dwell_ms: Keyword.get(config, :exam_machine_typing_max_dwell_ms, 5),
      clean_typing_min_chars: Keyword.get(config, :exam_clean_typing_min_chars, 500),
      clean_typing_max_correction_ratio:
        Keyword.get(config, :exam_clean_typing_max_correction_ratio, 0.01)
    }
  end

  @doc """
  `nil` when the submission has no proctoring data at all (not an exam
  block, or an exam attempt that predates this feature) - callers use this
  to decide whether to render the risk indicator at all. Only the fields
  the badge needs - see `detail/1` for the full breakdown.
  """
  @spec summary(map() | nil) ::
          %{
            risk_level: risk_level(),
            hard_evidence_count: non_neg_integer(),
            outlier_metrics: map()
          }
          | nil
  def summary(content) when is_map(content) do
    case content["risk_level"] do
      nil ->
        nil

      risk_level_str ->
        %{
          risk_level: String.to_existing_atom(risk_level_str),
          hard_evidence_count: content["hard_evidence_count"] || 0,
          outlier_metrics: content["outlier_metrics"] || %{}
        }
    end
  end

  def summary(_), do: nil

  @doc """
  The full stored breakdown for a submission - the points and the signals
  that produced them, every raw event count, every rate and what the
  other students usually do (whether or not it was flagged), absence and silence figures,
  typing totals, recorded incidents and the teacher's review, if any. Used
  by the submission-specific "why this verdict" modal. Same `nil` contract
  as `summary/1`; submissions saved before a field existed read it as
  empty/zero rather than crashing.
  """
  @spec detail(map() | nil) :: map() | nil
  def detail(content) when is_map(content) do
    case content["risk_level"] do
      nil ->
        nil

      risk_level_str ->
        %{
          risk_level: String.to_existing_atom(risk_level_str),
          points: content["points"],
          hard_evidence_count: content["hard_evidence_count"] || 0,
          outlier_metrics: content["outlier_metrics"] || %{},
          signals: content["signals"] || [],
          event_counts: content["event_counts"] || %{},
          rates: content["rates"] || %{},
          group_baselines: content["group_baselines"] || %{},
          elapsed_minutes: content["elapsed_minutes"],
          heartbeat_silence_seconds: content["heartbeat_silence_seconds"] || 0,
          away_incidents: content["away_incidents"] || 0,
          away_total_seconds: content["away_total_seconds"] || 0,
          mouse_away_seconds: content["mouse_away_seconds"] || 0,
          max_paste_chars: content["max_paste_chars"] || 0,
          typing: content["typing"] || %{},
          incidents: content["incidents"] || [],
          review: content["proctoring_review"]
        }
    end
  end

  def detail(_), do: nil
end
