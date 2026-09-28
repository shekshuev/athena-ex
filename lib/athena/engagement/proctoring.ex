defmodule Athena.Engagement.Proctoring do
  @moduledoc """
  Turns a `Athena.Engagement.ProctoringMonitor` reading into the
  `hard_evidence_count`/`outlier_metrics`/`risk_level` fields persisted on
  `Submission.content`, and the summary/detail read back out of them.

  Three-tier decision, not a single flat count:

  - **Hard evidence** (`printscreen_attempt`, `copy_attempt`, `cut_attempt`,
    `multi_tab_detected`, and tab-hides beyond the block's configured
    `allowed_blur_attempts`) - counted directly, no cohort comparison
    needed. There is no legitimate reason for any of these to happen at
    all during a locked-down question view (or, for blur, no legitimate
    reason to exceed a teacher-chosen absolute allowance), so a raw count
    is already meaningful evidence on its own.
  - **Behavioral outliers** (focus-loss rate, answer-change rate, paste
    ratio, right-click rate) - a raw count here means nothing by itself
    (an anxious student revising their answer 50 times looks identical, by
    the numbers, to a student who's actually cheating). These are only
    counted as evidence when `Athena.Engagement.ExamIntegrityStats` says
    the rate is a real statistical outlier *relative to everyone else
    taking this same exam right now* - so a hard/ambiguous question that
    makes the whole cohort hesitate more doesn't single anyone out.
  - **Telemetry silence** - neither a deliberate action (hard evidence) nor
    a cohort-relative rate (behavioral outlier), but evidence the entire
    signal channel went dark: the browser stopped reporting anything at
    all for longer than expected while the tab should have been visible.
    That can mean tampered/disabled tracking JS, or an ordinary crash/
    network drop - either way it's worth a closer look, so it factors
    into the same risk level rather than being a silent gap in the data.
    Self-heals: it's read live from `ProctoringMonitor`, never a sticky
    flag, so a transient blip clears the moment traffic resumes.

  Deliberately generic over any submission - a submission with no
  `risk_level` key in its content (i.e. everything except
  `quiz_exam`/`ticket_exam` in this iteration) is simply "no data", not an
  error, so callers can call `summary/1`/`detail/1` on any submission's
  content without special-casing the block type.
  """

  alias Athena.Engagement.{ExamIntegrityStats, ProctoringMonitor}

  @type risk_level :: :green | :yellow | :red

  @doc """
  Full evaluation of an exam attempt at its current reading (`%{counts:,
  elapsed_minutes:, silence_seconds:, max_silence_seconds:}`, from
  `ProctoringMonitor.snapshot/1` or `finalize/1`). Read-only - never
  mutates `ExamIntegrityStats`. Safe to call repeatedly on an in-progress
  attempt (the live risk indicator) as well as once at finalize time.
  """
  @spec evaluate(ProctoringMonitor.reading(), binary() | nil, binary(), non_neg_integer()) ::
          map()
  def evaluate(
        %{counts: counts, elapsed_minutes: elapsed_minutes} = reading,
        cohort_id,
        block_id,
        allowed_blur_attempts
      ) do
    silence_seconds = Map.get(reading, :max_silence_seconds, 0)

    blur_overage = max(counts.tab_hidden - allowed_blur_attempts, 0)

    hard_evidence_count =
      counts.printscreen_attempt + counts.copy_attempt + counts.cut_attempt +
        counts.multi_tab_detected + blur_overage

    # `window_blur` complements `tab_hidden` (same underlying "lost focus"
    # event, caught via two different browser APIs), so both feed the one
    # rate below rather than being two separate cohort-relative metrics -
    # `ProctoringMonitor.report_rates_to_exam_integrity_stats/1` reports the
    # cohort baseline using this identical formula, so the percentile
    # comparison stays apples-to-apples.
    rates = %{
      tab_hidden_per_minute: (counts.tab_hidden + counts.window_blur) / elapsed_minutes,
      answer_changed_per_minute: counts.answer_changed / elapsed_minutes,
      paste_ratio: counts.paste_ratio,
      right_click_per_minute: counts.right_click_attempt / elapsed_minutes
    }

    metric_percentiles = metric_percentiles(cohort_id, block_id, rates)
    outlier_metrics = filter_outliers(metric_percentiles)

    level = risk_level(hard_evidence_count, map_size(outlier_metrics), silence_seconds)

    %{
      "hard_evidence_count" => hard_evidence_count,
      "outlier_metrics" => outlier_metrics,
      "allowed_blur_attempts" => allowed_blur_attempts,
      "risk_level" => Atom.to_string(level),
      "event_counts" => stringify(Map.drop(counts, [:paste_ratio])),
      "rates" => stringify(rates),
      "metric_percentiles" => metric_percentiles,
      "elapsed_minutes" => elapsed_minutes,
      "blur_overage_count" => blur_overage,
      "heartbeat_silence_seconds" => silence_seconds
    }
  end

  # Percentile (0-100, rounded) for every rate metric, `nil` when the
  # cohort doesn't have enough peers yet - unlike `filter_outliers/1`, this
  # keeps every metric, flagged or not, so a submission's detail view can
  # show "here's where you stood" even for metrics that didn't cross the
  # threshold.
  defp metric_percentiles(cohort_id, block_id, rates) do
    for {metric, value} <- rates, into: %{} do
      percentile = ExamIntegrityStats.percentile_rank(cohort_id, block_id, metric, value)
      rounded = if is_number(percentile), do: Float.round(percentile, 1), else: nil
      {to_string(metric), rounded}
    end
  end

  defp filter_outliers(metric_percentiles) do
    for {metric, percentile} <- metric_percentiles,
        is_number(percentile),
        percentile >= percentile_outlier_threshold(),
        into: %{} do
      {metric, percentile}
    end
  end

  defp stringify(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  @doc """
  Three-tier risk verdict. `silence_seconds` defaults to `0` so existing
  2-arity call sites (and their evidence-only reasoning) keep working
  unchanged.
  """
  @spec risk_level(non_neg_integer(), non_neg_integer(), non_neg_integer()) :: risk_level()
  def risk_level(hard_evidence_count, outlier_metrics_count, silence_seconds \\ 0) do
    cond do
      hard_evidence_count >= hard_evidence_red_threshold() ->
        :red

      silence_seconds >= heartbeat_silence_red_threshold_seconds() ->
        :red

      outlier_metrics_count >= behavioral_outliers_red_threshold() ->
        :red

      hard_evidence_count > 0 or outlier_metrics_count > 0 or
          silence_seconds >= heartbeat_silence_yellow_threshold_seconds() ->
        :yellow

      true ->
        :green
    end
  end

  @doc """
  Every tunable threshold this module reads from config, for display in the
  methodology modal - keeps that copy from going stale if `config.exs`
  changes.
  """
  @spec thresholds() :: map()
  def thresholds do
    %{
      hard_evidence_red_threshold: hard_evidence_red_threshold(),
      behavioral_outliers_red_threshold: behavioral_outliers_red_threshold(),
      percentile_outlier_threshold: percentile_outlier_threshold(),
      min_sample_size_for_percentile: Keyword.get(config(), :min_sample_size_for_percentile, 15),
      heartbeat_silence_yellow_threshold_seconds: heartbeat_silence_yellow_threshold_seconds(),
      heartbeat_silence_red_threshold_seconds: heartbeat_silence_red_threshold_seconds()
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
  The full stored breakdown for a submission - every raw event count,
  every rate and its cohort percentile (whether or not it was flagged),
  the configured blur allowance and how much it was exceeded by, and the
  telemetry-silence figure. Used by the submission-specific "why this
  verdict" detail modal. Same `nil` contract as `summary/1`.
  """
  @spec detail(map() | nil) :: map() | nil
  def detail(content) when is_map(content) do
    case content["risk_level"] do
      nil ->
        nil

      risk_level_str ->
        %{
          risk_level: String.to_existing_atom(risk_level_str),
          hard_evidence_count: content["hard_evidence_count"] || 0,
          outlier_metrics: content["outlier_metrics"] || %{},
          event_counts: content["event_counts"] || %{},
          rates: content["rates"] || %{},
          metric_percentiles: content["metric_percentiles"] || %{},
          elapsed_minutes: content["elapsed_minutes"],
          allowed_blur_attempts: content["allowed_blur_attempts"],
          blur_overage_count: content["blur_overage_count"] || 0,
          heartbeat_silence_seconds: content["heartbeat_silence_seconds"] || 0
        }
    end
  end

  def detail(_), do: nil

  defp config, do: Application.get_env(:athena, Athena.Engagement, [])

  defp percentile_outlier_threshold,
    do: Keyword.get(config(), :exam_percentile_outlier_threshold, 90)

  defp hard_evidence_red_threshold,
    do: Keyword.get(config(), :exam_hard_evidence_red_threshold, 2)

  defp behavioral_outliers_red_threshold,
    do: Keyword.get(config(), :exam_behavioral_outliers_red_threshold, 2)

  defp heartbeat_silence_yellow_threshold_seconds,
    do: Keyword.get(config(), :exam_heartbeat_silence_yellow_threshold_seconds, 45)

  defp heartbeat_silence_red_threshold_seconds,
    do: Keyword.get(config(), :exam_heartbeat_silence_red_threshold_seconds, 120)
end
