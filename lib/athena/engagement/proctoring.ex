defmodule Athena.Engagement.Proctoring do
  @moduledoc """
  Turns a `Athena.Engagement.ProctoringMonitor` reading into the
  `hard_evidence_count`/`outlier_metrics`/`risk_level` fields persisted on
  `Submission.content`, and the summary read back out of them.

  Two-tier decision, not a single flat count:

  - **Hard evidence** (`printscreen_attempt`, `copy_attempt`, `cut_attempt`,
    `multi_tab_detected`) - counted directly, no cohort comparison needed.
    There is no legitimate reason for any of these to happen at all during
    a locked-down question view, so a raw count is already meaningful
    evidence on its own.
  - **Behavioral outliers** (focus-loss rate, answer-change rate, paste
    ratio) - a raw count here means nothing by itself (an anxious student
    revising their answer 50 times looks identical, by the numbers, to a
    student who's actually cheating). These are only counted as evidence
    when `Athena.Engagement.ExamIntegrityStats` says the rate is a real
    statistical outlier *relative to everyone else taking this same exam
    right now* - so a hard/ambiguous question that makes the whole cohort
    hesitate more doesn't single anyone out.

  Deliberately generic over any submission - a submission with no
  `risk_level` key in its content (i.e. everything except
  `quiz_exam`/`ticket_exam` in this iteration) is simply "no data", not an
  error, so callers can call `summary/1` on any submission's content
  without special-casing the block type.
  """

  alias Athena.Engagement.{ExamIntegrityStats, ProctoringMonitor}

  @type risk_level :: :green | :yellow | :red

  @doc """
  Full evaluation of an exam attempt at its current reading (`%{counts:,
  elapsed_minutes:}`, from `ProctoringMonitor.snapshot/1` or `finalize/1`).
  Read-only - never mutates `ExamIntegrityStats`. Safe to call repeatedly
  on an in-progress attempt (the live risk indicator) as well as once at
  finalize time.
  """
  @spec evaluate(ProctoringMonitor.reading(), binary() | nil, binary(), non_neg_integer()) ::
          map()
  def evaluate(
        %{counts: counts, elapsed_minutes: elapsed_minutes},
        cohort_id,
        block_id,
        allowed_blur_attempts
      ) do
    hard_evidence_count =
      counts.printscreen_attempt + counts.copy_attempt + counts.cut_attempt +
        counts.multi_tab_detected

    rates = %{
      tab_hidden_per_minute: counts.tab_hidden / elapsed_minutes,
      answer_changed_per_minute: counts.answer_changed / elapsed_minutes,
      paste_ratio: counts.paste_ratio
    }

    outlier_metrics = outlier_metrics(cohort_id, block_id, rates)
    level = risk_level(hard_evidence_count, map_size(outlier_metrics))

    %{
      "hard_evidence_count" => hard_evidence_count,
      "outlier_metrics" => outlier_metrics,
      "allowed_blur_attempts" => allowed_blur_attempts,
      "risk_level" => Atom.to_string(level)
    }
  end

  defp outlier_metrics(cohort_id, block_id, rates) do
    for {metric, value} <- rates,
        percentile = ExamIntegrityStats.percentile_rank(cohort_id, block_id, metric, value),
        is_number(percentile),
        percentile >= percentile_outlier_threshold(),
        into: %{} do
      {to_string(metric), Float.round(percentile, 1)}
    end
  end

  @spec risk_level(non_neg_integer(), non_neg_integer()) :: risk_level()
  def risk_level(hard_evidence_count, outlier_metrics_count) do
    cond do
      hard_evidence_count >= hard_evidence_red_threshold() -> :red
      outlier_metrics_count >= behavioral_outliers_red_threshold() -> :red
      hard_evidence_count > 0 or outlier_metrics_count > 0 -> :yellow
      true -> :green
    end
  end

  @doc """
  `nil` when the submission has no proctoring data at all (not an exam
  block, or an exam attempt that predates this feature) - callers use this
  to decide whether to render the risk indicator at all.
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

  defp config, do: Application.get_env(:athena, Athena.Engagement, [])

  defp percentile_outlier_threshold,
    do: Keyword.get(config(), :exam_percentile_outlier_threshold, 90)

  defp hard_evidence_red_threshold,
    do: Keyword.get(config(), :exam_hard_evidence_red_threshold, 2)

  defp behavioral_outliers_red_threshold,
    do: Keyword.get(config(), :exam_behavioral_outliers_red_threshold, 2)
end
