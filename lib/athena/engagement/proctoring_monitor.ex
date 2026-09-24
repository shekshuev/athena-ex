defmodule Athena.Engagement.ProctoringMonitor do
  @moduledoc """
  Ephemeral, per-exam-attempt accumulator of academic-integrity signal
  counts - see `Athena.Engagement.Proctoring` for how these raw counts turn
  into a risk level. One process per submission id (the parent submission
  of one `quiz_exam`/`ticket_exam` attempt), started lazily by the first
  `report_events/4` call (essentially at page load, since the exam
  LiveViews forward every client engagement batch here, not just the ones
  containing a proctoring-relevant event) and stopped either explicitly by
  `finalize/1` (the exam was submitted) or by idle timeout (an abandoned
  attempt - a closed tab, a crash, ...).

  Deliberately pure in-memory and fed by direct casts from the exam
  LiveViews' own `engagement_batch` handler (and, for the couple of
  signals the *server* originates - `answer_changed`, `code_run_attempt` -
  from `AthenaWeb.LearnLive.EngagementSignals`), not by a PubSub
  subscription like `Athena.Engagement.BlockStats` - there is nothing to
  bootstrap from the database (a fresh attempt has no prior signal), and
  nothing is written to the database until `finalize/1`. That's the whole
  point of accumulating here instead of writing a row per event during a
  live, timed exam.

  On every update this also pushes the attempt's current per-minute rates
  into `Athena.Engagement.ExamIntegrityStats` (keyed by the exam's
  `{cohort_id, block_id}`) - that's what lets the live risk indicator
  compare this student to peers taking the same exam right now, instead of
  just against a flat number.
  """

  use GenServer

  alias Athena.Engagement.ExamIntegrityStats

  @registry Athena.Engagement.ProctoringMonitorRegistry
  @supervisor Athena.Engagement.ProctoringMonitorSupervisor

  # Every event type this monitor's counters care about. `paste_detected`
  # feeds a running ratio (not a plain count - see `paste_totals`);
  # everything else here is a plain counter. Anything not in this list
  # (viewport_enter, scroll_milestone, video_*, ...) is silently ignored -
  # it physically cannot arrive from an exam page's sub-questions anyway
  # (see `Athena.Engagement.Event`'s catalog for which block types emit
  # what), but filtering defensively costs nothing.
  @tracked_event_types [
    :tab_hidden,
    :window_blur,
    :printscreen_attempt,
    :copy_attempt,
    :cut_attempt,
    :multi_tab_detected,
    :paste_detected,
    :answer_changed,
    :code_run_attempt
  ]

  @type counts :: %{
          tab_hidden: non_neg_integer(),
          window_blur: non_neg_integer(),
          printscreen_attempt: non_neg_integer(),
          copy_attempt: non_neg_integer(),
          cut_attempt: non_neg_integer(),
          multi_tab_detected: non_neg_integer(),
          answer_changed: non_neg_integer(),
          code_run_attempt: non_neg_integer(),
          paste_ratio: float()
        }

  @type reading :: %{counts: counts(), elapsed_minutes: float()}

  # Public API

  @doc "The event types this monitor actually accumulates - used to decide whether a server-originated event is even worth forwarding."
  @spec tracked_event_types() :: [atom()]
  def tracked_event_types, do: @tracked_event_types

  @doc "Looks up (or lazily starts) the process for this submission and returns its pid."
  @spec get_or_start(binary(), binary() | nil, binary()) :: {:ok, pid()}
  def get_or_start(submission_id, cohort_id, block_id) do
    case Registry.lookup(@registry, submission_id) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        case DynamicSupervisor.start_child(
               @supervisor,
               {__MODULE__, {submission_id, cohort_id, block_id}}
             ) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
        end
    end
  end

  @doc """
  Fire-and-forget: casts a batch of already-normalized events into the
  attempt's counters. Callers do not need to pre-filter - irrelevant event
  types are simply ignored here (see `@tracked_event_types`).
  """
  @spec report_events(binary(), binary() | nil, binary(), [map()]) :: :ok
  def report_events(_submission_id, _cohort_id, _block_id, []), do: :ok

  def report_events(submission_id, cohort_id, block_id, events) do
    {:ok, pid} = get_or_start(submission_id, cohort_id, block_id)
    GenServer.cast(pid, {:events, events})
  end

  @doc """
  Current counts and elapsed minutes, live. Returns an all-zero reading
  (not an error) if no process is running - either nothing has happened
  yet, or the attempt already finalized.
  """
  @spec snapshot(binary()) :: reading()
  def snapshot(submission_id) do
    case Registry.lookup(@registry, submission_id) do
      [{pid, _}] -> GenServer.call(pid, :snapshot)
      [] -> %{counts: initial_counts(), elapsed_minutes: min_elapsed_minutes()}
    end
  end

  @doc "Reads the final reading and stops the process. Idempotent - safe to call on an attempt with no process."
  @spec finalize(binary()) :: reading()
  def finalize(submission_id) do
    reading = snapshot(submission_id)

    case Registry.lookup(@registry, submission_id) do
      [{pid, _}] -> GenServer.stop(pid, :normal)
      [] -> :ok
    end

    reading
  end

  @doc false
  def child_spec({submission_id, cohort_id, block_id}) do
    %{
      id: {__MODULE__, submission_id},
      start: {__MODULE__, :start_link, [{submission_id, cohort_id, block_id}]},
      restart: :temporary
    }
  end

  @doc false
  def start_link({submission_id, cohort_id, block_id}) do
    GenServer.start_link(__MODULE__, {submission_id, cohort_id, block_id},
      name: {:via, Registry, {@registry, submission_id}}
    )
  end

  # Server callbacks

  @impl true
  def init({submission_id, cohort_id, block_id}) do
    schedule_idle_check()

    now = DateTime.utc_now()

    {:ok,
     %{
       submission_id: submission_id,
       cohort_id: cohort_id,
       block_id: block_id,
       started_at: now,
       counts: initial_counts(),
       paste_totals: %{pasted_chars: 0, total_chars: 0},
       last_event_at: now
     }}
  end

  @impl true
  def handle_cast({:events, events}, state) do
    {counts, paste_totals} =
      Enum.reduce(events, {state.counts, state.paste_totals}, &apply_event/2)

    state = %{
      state
      | counts: counts,
        paste_totals: paste_totals,
        last_event_at: DateTime.utc_now()
    }

    report_rates_to_exam_integrity_stats(state)

    Phoenix.PubSub.broadcast(
      Athena.PubSub,
      "proctoring:#{state.submission_id}",
      {:proctoring_updated, state.submission_id}
    )

    {:noreply, state}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, reading(state), state}
  end

  @impl true
  def handle_info(:check_idle, state) do
    idle_for_ms = DateTime.diff(DateTime.utc_now(), state.last_event_at, :millisecond)

    if idle_for_ms >= idle_timeout_seconds() * 1000 do
      {:stop, :normal, state}
    else
      schedule_idle_check()
      {:noreply, state}
    end
  end

  # Internals

  defp apply_event(%{event_type: :paste_detected} = event, {counts, paste_totals}) do
    pasted = event.payload["pasted_chars"] || 0
    total = event.payload["total_chars"] || 0

    {counts,
     %{
       paste_totals
       | pasted_chars: paste_totals.pasted_chars + pasted,
         total_chars: paste_totals.total_chars + total
     }}
  end

  defp apply_event(%{event_type: event_type} = _event, {counts, paste_totals})
       when event_type in @tracked_event_types do
    {Map.update!(counts, event_type, &(&1 + 1)), paste_totals}
  end

  defp apply_event(_event, acc), do: acc

  defp reading(state) do
    elapsed_minutes =
      max(
        DateTime.diff(DateTime.utc_now(), state.started_at, :second) / 60.0,
        min_elapsed_minutes()
      )

    paste_ratio = paste_ratio(state.paste_totals)

    %{counts: Map.put(state.counts, :paste_ratio, paste_ratio), elapsed_minutes: elapsed_minutes}
  end

  # A floor, never zero - `elapsed_minutes` is used as a division
  # denominator in `Athena.Engagement.Proctoring.evaluate/4` (rates per
  # minute), and this same floor is what `snapshot/1` falls back to when no
  # process has started yet (nothing reported = zero elapsed time by
  # definition, but zero would make that division blow up).
  defp min_elapsed_minutes, do: 1 / 60

  defp paste_ratio(%{total_chars: 0}), do: 0.0
  defp paste_ratio(%{pasted_chars: pasted, total_chars: total}), do: pasted / total

  defp report_rates_to_exam_integrity_stats(state) do
    %{counts: counts, elapsed_minutes: elapsed_minutes} = reading(state)

    ExamIntegrityStats.report_rate(
      state.cohort_id,
      state.block_id,
      state.submission_id,
      :tab_hidden_per_minute,
      counts.tab_hidden / elapsed_minutes
    )

    ExamIntegrityStats.report_rate(
      state.cohort_id,
      state.block_id,
      state.submission_id,
      :answer_changed_per_minute,
      counts.answer_changed / elapsed_minutes
    )

    ExamIntegrityStats.report_rate(
      state.cohort_id,
      state.block_id,
      state.submission_id,
      :paste_ratio,
      counts.paste_ratio
    )
  end

  defp initial_counts do
    %{
      tab_hidden: 0,
      window_blur: 0,
      printscreen_attempt: 0,
      copy_attempt: 0,
      cut_attempt: 0,
      multi_tab_detected: 0,
      answer_changed: 0,
      code_run_attempt: 0,
      paste_ratio: 0.0
    }
  end

  # Checked at most once a minute in production, scales down with a short
  # configured timeout so tests don't have to wait a full minute for the
  # first check. The default is deliberately more generous than
  # `BlockStats`' 30 minutes - an exam attempt can legitimately sit open
  # (within its own `expires_at`) for as long as the block's configured
  # time limit, and this monitor must not reap its counters mid-attempt.
  defp schedule_idle_check do
    delay_ms = (idle_timeout_seconds() * 1000) |> min(:timer.minutes(1)) |> max(50) |> trunc()
    Process.send_after(self(), :check_idle, delay_ms)
  end

  defp config, do: Application.get_env(:athena, Athena.Engagement, [])

  defp idle_timeout_seconds do
    Keyword.get(config(), :proctoring_monitor_idle_timeout_minutes, 180) * 60
  end
end
