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
    cheating), so a rate only counts when it is a real statistical outlier
    *relative to everyone taking this same exam right now* **and** above an
    absolute floor (a cohort of zeros makes any non-zero value a "100th
    percentile"), or - when there aren't enough peers to compare against -
    above an absolute fallback.

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
    {:tab_hidden_per_minute, 2, true},
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
      tab_hidden_per_minute: (count(counts, :tab_hidden) + count(counts, :window_blur)) / elapsed,
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
  @spec evaluate(ProctoringMonitor.reading() | map(), binary() | nil, binary()) :: map()
  def evaluate(%{counts: counts} = reading, cohort_id, block_id) do
    t = thresholds()

    silence_seconds =
      max(Map.get(reading, :max_silence_seconds, 0), Map.get(reading, :max_offline_seconds, 0))

    eligible = rates(reading)
    all = all_rates(reading)

    percentiles = metric_percentiles(cohort_id, block_id, eligible)
    relative = relative_signals(eligible, percentiles, t)

    signals =
      hard_signals(counts) ++
        away_signals(reading, t) ++
        silence_signals(silence_seconds, t) ++
        split_screen_signals(counts) ++
        typing_signals(Map.get(reading, :typing, %{}), t) ++
        relative

    points = signals |> Enum.map(& &1["points"]) |> Enum.sum()

    outlier_metrics =
      for %{"key" => key, "basis" => basis} = signal <- relative, into: %{} do
        {key, if(basis == "percentile", do: percentiles[key], else: signal["percentile"])}
      end

    %{
      "hard_evidence_count" => Enum.sum(for event <- @hard_events, do: count(counts, event)),
      "outlier_metrics" => outlier_metrics,
      "risk_level" => points |> risk_level() |> Atom.to_string(),
      "points" => points,
      "signals" => signals,
      "event_counts" => stringify(Map.drop(counts, [:paste_ratio])),
      "rates" => stringify(all),
      "metric_percentiles" =>
        Map.new(all, fn {k, _} -> {to_string(k), percentiles[to_string(k)]} end),
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

  # Percentile (0-100, rounded) of every judged rate, `nil` when the cohort
  # doesn't have enough peers yet.
  defp metric_percentiles(cohort_id, block_id, rates) do
    for {metric, value} <- rates, into: %{} do
      percentile = ExamIntegrityStats.percentile_rank(cohort_id, block_id, metric, value)
      rounded = if is_number(percentile), do: Float.round(percentile, 1), else: nil
      {to_string(metric), rounded}
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

  defp relative_signals(rates, percentiles, t) do
    for {metric, points, _per_minute} <- @relative_metrics,
        Map.has_key?(rates, metric),
        signal = relative_signal(metric, points, rates[metric], percentiles[to_string(metric)], t),
        do: signal
  end

  defp relative_signal(metric, points, value, percentile, t) do
    cond do
      is_number(percentile) and percentile >= t.percentile_outlier_threshold and
          value >= t.floors[metric] ->
        %{
          "key" => to_string(metric),
          "points" => points,
          "value" => value,
          "percentile" => percentile,
          "basis" => "percentile"
        }

      is_nil(percentile) and value >= t.fallbacks[metric] ->
        %{
          "key" => to_string(metric),
          "points" => points,
          "value" => value,
          "percentile" => nil,
          "basis" => "fallback"
        }

      true ->
        nil
    end
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
      percentile_outlier_threshold: Keyword.get(config, :exam_percentile_outlier_threshold, 95),
      min_peers: Keyword.get(config, :exam_min_peers, 8),
      min_minutes_for_rates: Keyword.get(config, :exam_min_minutes_for_rates, 3),
      floors: Map.merge(@default_floors, Map.new(Keyword.get(config, :exam_metric_floors, %{}))),
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
  that produced them, every raw event count, every rate and its cohort
  percentile (whether or not it was flagged), absence and silence figures,
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
          metric_percentiles: content["metric_percentiles"] || %{},
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
