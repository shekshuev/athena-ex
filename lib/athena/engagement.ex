defmodule Athena.Engagement do
  @moduledoc """
  Public API for the Engagement context.

  Collects semantic, business-meaningful telemetry about how students move
  through course content (dwell time, scroll depth, video controls, pasted
  answers, backtracking to earlier material, ...) and turns it into metrics a
  teacher can act on and a researcher can analyze - never raw pointer/keystroke
  data.

  Delegates to specialized internal modules:
  - `Events`: recording raw telemetry and reading raw timelines.
  - `Metrics`: turning raw events into the metric catalog (per block type,
    per section, per cohort/student).
  - `BlockStats`: warm, incrementally-updated per-(cohort, block) running
    statistics, used both for nudge decisions and for live dashboard reads -
    without ever issuing a query per incoming event.
  - `ProctoringMonitor`: warm, per-exam-attempt academic-integrity signal
    counts (focus loss, PrintScreen, copy/cut attempts), accumulated in
    memory during a timed `quiz_exam`/`ticket_exam` attempt.
  - `Proctoring`: turns `ProctoringMonitor` counts into the risk-level
    fields persisted on a submission, and the summary read back out of them.
  """

  alias Athena.Engagement.{Events, BlockStats, Metrics, Proctoring, ProctoringMonitor}

  @doc """
  Records one batch of raw events reported by a single Player session, then
  broadcasts each event to its scoped PubSub topics so that any live
  `BlockStats` process and any open teacher "live replay" view pick it up
  incrementally.
  """
  @spec record_events(binary(), binary() | nil, binary(), [map()]) ::
          {:ok, non_neg_integer()} | {:error, :empty}
  def record_events(account_id, cohort_id, session_id, events) do
    case Events.record_events(account_id, cohort_id, session_id, events) do
      {:ok, {count, rows}} ->
        Enum.each(rows, &notify_engagement_subscribers/1)
        {:ok, count}

      {:error, :empty} = error ->
        error
    end
  end

  defdelegate get_session_timeline(account_id, session_id), to: Events
  defdelegate list_events_for_scope(block_ids, cohort_id \\ nil), to: Events
  defdelegate normalize_event(raw_event, section_id), to: Events

  @doc "The event types `report_proctoring_events/2` actually accumulates - used by callers to filter a batch before forwarding."
  defdelegate proctoring_tracked_event_types(), to: ProctoringMonitor, as: :tracked_event_types

  @doc "Fire-and-forget: accumulates already-normalized proctoring events for one exam attempt."
  defdelegate report_proctoring_events(submission_id, events),
    to: ProctoringMonitor,
    as: :report_events

  @doc "Reads the final accumulated counts for one exam attempt and stops accumulating."
  defdelegate finalize_proctoring(submission_id), to: ProctoringMonitor, as: :finalize

  @doc "Builds the `cheat_count`/`proctoring` fields to merge into a `Submission.content` map."
  defdelegate proctoring_content_fields(counts, allowed_blur_attempts),
    to: Proctoring,
    as: :build_content_fields

  @doc "Risk-level summary of a submission's proctoring data, or `nil` if it has none."
  defdelegate proctoring_summary(content), to: Proctoring, as: :summary

  defdelegate get_metrics(scope), to: Metrics
  defdelegate funnel(block_id, cohort_id \\ nil), to: Metrics
  defdelegate correlate(measurements_a, measurements_b), to: Metrics
  defdelegate time_series(block_id, cohort_id, metric), to: Metrics
  defdelegate export_wide_table(course_id, cohort_ids), to: Metrics
  defdelegate flag_concerns(metrics), to: Metrics
  defdelegate student_radar(cohort_id, course_id, opts \\ []), to: Metrics
  defdelegate cohort_flag_profile(cohort_id, course_id, opts \\ []), to: Metrics
  defdelegate radar_axes(), to: Metrics
  defdelegate section_flag_totals(cohort_id, course_id, opts \\ []), to: Metrics
  defdelegate activity_heatmap(cohort_id, course_id, opts \\ []), to: Metrics
  defdelegate course_funnel(cohort_id, course_id, opts \\ []), to: Metrics
  defdelegate active_students_trend(cohort_id, course_id, opts \\ []), to: Metrics
  defdelegate nudge_correction_rate(cohort_id, course_id, opts \\ []), to: Metrics
  defdelegate histogram(cohort_id, block_id), to: BlockStats

  @nudge_percentile_floor 10.0

  @doc """
  The percentile-rank cutoff `evaluate_nudge/5` nudges below (once a
  block/cohort pair has enough samples) - exposed so a chart can draw the
  exact line the algorithm itself decides against, instead of a teacher
  having to take the threshold on faith.
  """
  @spec nudge_percentile_floor() :: float()
  def nudge_percentile_floor, do: @nudge_percentile_floor

  @doc """
  Decides whether a student should be nudged for having dwelled on a block
  for `elapsed_seconds` - called from the Player right after a
  `viewport_exit` is recorded, using data already loaded by the caller
  (`resolved_rule` from `Athena.Content.Policy.resolve_engagement_rule/2`,
  `nudges_enabled` from the student's `Cohort`), so this never itself issues
  a database query.

  Two-tier decision, matching the "analysis methods" section of the plan:
  once a block/cohort pair has accumulated at least
  `min_sample_size_for_percentile` dwell samples (config), the decision is
  relative to the cohort's own distribution (below the 10th percentile -
  read comparable to a "guessed" pace, not a difficulty-invariant fixed
  number). Below that sample size there isn't yet a meaningful distribution
  to compare against, so it falls back to the block's configured absolute
  floor (`expected_seconds * fast_ratio_threshold`) if one is set; with
  neither enough data nor a configured floor, it does not nudge - guessing
  blindly would be worse than staying silent.
  """
  @spec evaluate_nudge(binary() | nil, binary(), map(), number(), boolean()) :: :nudge | :ok
  def evaluate_nudge(_cohort_id, _block_id, _resolved_rule, _elapsed_seconds, false), do: :ok

  def evaluate_nudge(_cohort_id, _block_id, %{nudge_enabled: false}, _elapsed_seconds, true),
    do: :ok

  def evaluate_nudge(cohort_id, block_id, resolved_rule, elapsed_seconds, true) do
    min_sample_size = Keyword.get(engagement_config(), :min_sample_size_for_percentile, 15)
    snapshot = BlockStats.snapshot(cohort_id, block_id)

    cond do
      snapshot.n >= min_sample_size ->
        case BlockStats.percentile_rank(cohort_id, block_id, elapsed_seconds) do
          percentile when is_number(percentile) and percentile <= @nudge_percentile_floor ->
            :nudge

          _ ->
            :ok
        end

      is_number(resolved_rule[:expected_seconds]) and
          is_number(resolved_rule[:fast_ratio_threshold]) ->
        floor = resolved_rule.expected_seconds * resolved_rule.fast_ratio_threshold
        if elapsed_seconds < floor, do: :nudge, else: :ok

      true ->
        :ok
    end
  end

  defp engagement_config, do: Application.get_env(:athena, Athena.Engagement, [])

  @doc false
  defp notify_engagement_subscribers(row) do
    event = %{
      block_id: row.block_id,
      section_id: row.section_id,
      account_id: row.account_id,
      cohort_id: row.cohort_id,
      session_id: row.session_id,
      event_type: row.event_type,
      payload: row.payload,
      occurred_at: row.occurred_at
    }

    Phoenix.PubSub.broadcast(
      Athena.PubSub,
      "engagement:#{row.cohort_id}:#{row.block_id}",
      {:engagement_event, event}
    )

    Phoenix.PubSub.broadcast(
      Athena.PubSub,
      "engagement_session:#{row.account_id}:#{row.session_id}",
      {:engagement_event, event}
    )
  end
end
