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

  On every update this also pushes the attempt's current rates into
  `Athena.Engagement.ExamIntegrityStats` (keyed by the exam's
  `{cohort_id, block_id}`) - that's what lets the live risk indicator
  compare this attempt to peers taking the same exam right now, instead of
  just against a flat number.

  Besides plain counters it keeps a few aggregates that a counter can't
  express: the merged "away from the exam" intervals (tab hidden, window
  blurred, fullscreen exited - overlapping ones are one absence, not
  several), the longest stretch the telemetry channel itself went quiet
  (and a short list of those incidents, so they survive into the
  submission), typing-dynamics totals (never individual keystrokes), and
  the longest single paste.
  """

  use GenServer

  alias Athena.Engagement.{ExamIntegrityStats, Proctoring}

  @registry Athena.Engagement.ProctoringMonitorRegistry
  @supervisor Athena.Engagement.ProctoringMonitorSupervisor

  @max_incidents 100
  @max_away_intervals 500

  # Event types that are a plain `counts` bump.
  @counted_event_types [
    :tab_hidden,
    :window_blur,
    :printscreen_attempt,
    :copy_attempt,
    :cut_attempt,
    :multi_tab_detected,
    :answer_changed,
    :code_run_attempt,
    :right_click_attempt,
    :bulk_insert,
    :offline_period,
    :mouse_left,
    :fullscreen_exit
  ]

  # Event types with bespoke handling (an interval, an aggregate, a ratio).
  @special_event_types [
    :paste_detected,
    :typing_summary,
    :tab_visible,
    :window_focus,
    :window_geometry_changed
  ]

  # Every event type this monitor's counters care about. Anything not in
  # this list (viewport_enter, scroll_milestone, video_*, ...) is silently
  # ignored - it physically cannot arrive from an exam page's sub-questions
  # anyway (see `Athena.Engagement.Event`'s catalog for which block types
  # emit what), but filtering defensively costs nothing.
  @tracked_event_types @counted_event_types ++ @special_event_types

  @type counts :: %{
          tab_hidden: non_neg_integer(),
          window_blur: non_neg_integer(),
          printscreen_attempt: non_neg_integer(),
          copy_attempt: non_neg_integer(),
          cut_attempt: non_neg_integer(),
          multi_tab_detected: non_neg_integer(),
          answer_changed: non_neg_integer(),
          code_run_attempt: non_neg_integer(),
          right_click_attempt: non_neg_integer(),
          bulk_insert: non_neg_integer(),
          offline_period: non_neg_integer(),
          mouse_left: non_neg_integer(),
          fullscreen_exit: non_neg_integer(),
          large_paste: non_neg_integer(),
          split_screen: non_neg_integer(),
          paste_ratio: float()
        }

  @type typing :: %{
          keys: non_neg_integer(),
          dwell_sum: float(),
          cv_sum: float(),
          pauses: non_neg_integer(),
          max_clean_run: non_neg_integer(),
          chars_typed: non_neg_integer(),
          chars_deleted: non_neg_integer()
        }

  @type reading :: %{
          counts: counts(),
          elapsed_minutes: float(),
          silence_seconds: non_neg_integer(),
          max_silence_seconds: non_neg_integer(),
          max_offline_seconds: non_neg_integer(),
          away_incidents: non_neg_integer(),
          away_count: non_neg_integer(),
          away_total_seconds: non_neg_integer(),
          mouse_away_seconds: non_neg_integer(),
          max_paste_chars: non_neg_integer(),
          typing: typing(),
          incidents: [map()]
        }

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
  A liveness ping, distinct from `report_events/4` - always starts the
  monitor (even with nothing to report) so "an empty batch" and "the
  telemetry channel has gone completely silent" stay distinguishable. Sent
  by the client on every flush tick regardless of whether anything
  interesting happened, so a gap between two of these is itself a signal
  (see `Athena.Engagement.Proctoring` for how it factors into risk level).
  """
  @spec heartbeat(binary(), binary() | nil, binary()) :: :ok
  def heartbeat(submission_id, cohort_id, block_id) do
    {:ok, pid} = get_or_start(submission_id, cohort_id, block_id)
    GenServer.cast(pid, :heartbeat)
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
      [] -> empty_reading()
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
       max_paste_chars: 0,
       last_event_at: now,
       max_silence_seconds: 0,
       max_offline_seconds: 0,
       incidents: [],
       away_intervals: [],
       mouse_away_ms: 0,
       typing: initial_typing(),
       tab_hidden: false
     }}
  end

  @impl true
  def handle_cast({:events, events}, state) do
    state = note_activity(state)
    state = Enum.reduce(events, state, &apply_event/2)
    state = %{state | tab_hidden: Enum.reduce(events, state.tab_hidden, &apply_tab_hidden/2)}

    report_rates_to_exam_integrity_stats(state)
    broadcast_updated(state)

    {:noreply, state}
  end

  @impl true
  def handle_cast(:heartbeat, state) do
    state = note_activity(state)
    broadcast_updated(state)

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
      # A silent-but-not-yet-idle gap doesn't get its own cast to trigger a
      # broadcast (that's the whole point - nothing is arriving), so this
      # otherwise-idle-only tick doubles as the only thing that pushes a
      # growing silence out to live viewers (the group monitor) while the
      # attempt is still technically in progress.
      if current_silence_seconds(state) > notable_silence_seconds() do
        broadcast_updated(state)
      end

      schedule_idle_check()
      {:noreply, state}
    end
  end

  # Internals

  defp apply_event(%{event_type: :paste_detected} = event, state) do
    payload = payload(event)
    pasted = payload["pasted_chars"] || 0
    total = payload["total_chars"] || 0

    paste_totals = %{
      state.paste_totals
      | pasted_chars: state.paste_totals.pasted_chars + pasted,
        total_chars: state.paste_totals.total_chars + total
    }

    counts =
      if pasted >= Proctoring.thresholds().large_paste_chars,
        do: Map.update!(state.counts, :large_paste, &(&1 + 1)),
        else: state.counts

    %{
      state
      | paste_totals: paste_totals,
        counts: counts,
        max_paste_chars: max(state.max_paste_chars, pasted)
    }
  end

  defp apply_event(%{event_type: :typing_summary} = event, state) do
    p = payload(event)
    keys = int(p["n"])

    typing = %{
      state.typing
      | keys: state.typing.keys + keys,
        dwell_sum: state.typing.dwell_sum + num(p["median_dwell_ms"]) * keys,
        cv_sum: state.typing.cv_sum + num(p["flight_cv"]) * keys,
        pauses: state.typing.pauses + int(p["pauses"]),
        max_clean_run: max(state.typing.max_clean_run, int(p["max_clean_run"])),
        chars_typed: state.typing.chars_typed + int(p["chars_typed"]),
        chars_deleted: state.typing.chars_deleted + int(p["chars_deleted"])
    }

    %{state | typing: typing}
  end

  defp apply_event(%{event_type: type} = event, state)
       when type in [:tab_visible, :window_focus] do
    add_away_interval(state, event)
  end

  defp apply_event(%{event_type: :window_geometry_changed} = event, state) do
    if payload(event)["split"] == true,
      do: %{state | counts: Map.update!(state.counts, :split_screen, &(&1 + 1))},
      else: state
  end

  defp apply_event(%{event_type: :fullscreen_exit} = event, state) do
    state
    |> bump(:fullscreen_exit)
    |> add_away_interval(event)
  end

  defp apply_event(%{event_type: :offline_period} = event, state) do
    seconds = div(int(payload(event)["duration_ms"]), 1000)

    state
    |> bump(:offline_period)
    |> Map.update!(:max_offline_seconds, &max(&1, seconds))
  end

  defp apply_event(%{event_type: :mouse_left} = event, state) do
    state
    |> bump(:mouse_left)
    |> Map.update!(:mouse_away_ms, &(&1 + int(payload(event)["duration_ms"])))
  end

  defp apply_event(%{event_type: type}, state) when type in @counted_event_types,
    do: bump(state, type)

  defp apply_event(_event, state), do: state

  defp bump(state, key), do: %{state | counts: Map.update!(state.counts, key, &(&1 + 1))}

  # The interval ends when the "back" event was recorded and began
  # `duration_ms` earlier; overlapping intervals (Alt+Tab fires both
  # `window_focus` and, if the browser got fully covered, `tab_visible`)
  # are merged on read, so one absence is never counted twice.
  defp add_away_interval(state, event) do
    duration_ms = int(payload(event)["duration_ms"])

    if duration_ms > 0 do
      finished_ms = finished_at_ms(event)
      interval = {finished_ms - duration_ms, finished_ms}
      %{state | away_intervals: Enum.take([interval | state.away_intervals], @max_away_intervals)}
    else
      state
    end
  end

  defp finished_at_ms(%{occurred_at: %DateTime{} = at}), do: DateTime.to_unix(at, :millisecond)
  defp finished_at_ms(_event), do: System.os_time(:millisecond)

  defp payload(%{payload: payload}) when is_map(payload), do: payload
  defp payload(_event), do: %{}

  defp int(value) when is_integer(value) and value > 0, do: value
  defp int(value) when is_float(value) and value > 0, do: trunc(value)
  defp int(_value), do: 0

  defp num(value) when is_number(value) and value > 0, do: value * 1.0
  defp num(_value), do: 0.0

  defp apply_tab_hidden(%{event_type: :tab_hidden}, _tab_hidden), do: true
  defp apply_tab_hidden(%{event_type: :tab_visible}, _tab_hidden), do: false
  defp apply_tab_hidden(_event, tab_hidden), do: tab_hidden

  # Bumps `last_event_at` and folds the gap since the previous activity
  # (event batch or heartbeat, whichever was more recent) into the running
  # max - called from both `{:events, _}` and `:heartbeat` casts so a real
  # event closes out a silent gap exactly the same way a heartbeat does.
  # A gap long enough to matter is also remembered as an incident (when it
  # started and how long it lasted) so it survives into the submission and
  # shows up on the teacher's timeline - the max alone can't say *when*.
  defp note_activity(state) do
    now = DateTime.utc_now()
    gap = current_silence_seconds(state, now)

    incidents =
      if gap >= Proctoring.thresholds().heartbeat_silence_yellow_threshold_seconds do
        incident = %{
          "type" => "silence",
          "at" => DateTime.to_iso8601(state.last_event_at),
          "seconds" => gap
        }

        Enum.take(state.incidents ++ [incident], -@max_incidents)
      else
        state.incidents
      end

    %{
      state
      | last_event_at: now,
        max_silence_seconds: max(state.max_silence_seconds, gap),
        incidents: incidents
    }
  end

  defp broadcast_updated(state) do
    Phoenix.PubSub.broadcast(
      Athena.PubSub,
      "proctoring:#{state.submission_id}",
      {:proctoring_updated, state.submission_id}
    )
  end

  # The live, still-open gap since the last activity of any kind - not the
  # same as `max_silence_seconds`, which is the largest *closed* gap so
  # far. Deliberately `0` while the tab is legitimately backgrounded
  # (`tab_hidden`) - that case is already covered by the away-time signal
  # itself and going quiet while backgrounded is expected, not suspicious.
  defp current_silence_seconds(state, now \\ DateTime.utc_now())

  defp current_silence_seconds(%{tab_hidden: true}, _now), do: 0

  defp current_silence_seconds(state, now),
    do: DateTime.diff(now, state.last_event_at, :second)

  # Threshold for the idle-check tick to bother broadcasting a live update
  # purely because of silence - deliberately below the configured yellow
  # threshold, so the monitor's live badge is already trending before it
  # flips color, not appearing to jump straight there.
  defp notable_silence_seconds, do: 20

  defp reading(state) do
    elapsed_minutes =
      max(
        DateTime.diff(DateTime.utc_now(), state.started_at, :second) / 60.0,
        min_elapsed_minutes()
      )

    silence_seconds = current_silence_seconds(state)
    {away_incidents, away_count, away_total_seconds} = away_stats(state.away_intervals)

    %{
      counts: Map.put(state.counts, :paste_ratio, paste_ratio(state.paste_totals)),
      elapsed_minutes: elapsed_minutes,
      silence_seconds: silence_seconds,
      max_silence_seconds: max(state.max_silence_seconds, silence_seconds),
      max_offline_seconds: state.max_offline_seconds,
      away_incidents: away_incidents,
      away_count: away_count,
      away_total_seconds: away_total_seconds,
      mouse_away_seconds: div(state.mouse_away_ms, 1000),
      max_paste_chars: state.max_paste_chars,
      typing: state.typing,
      incidents: state.incidents
    }
  end

  defp empty_reading do
    %{
      counts: initial_counts(),
      elapsed_minutes: min_elapsed_minutes(),
      silence_seconds: 0,
      max_silence_seconds: 0,
      max_offline_seconds: 0,
      away_incidents: 0,
      away_count: 0,
      away_total_seconds: 0,
      mouse_away_seconds: 0,
      max_paste_chars: 0,
      typing: initial_typing(),
      incidents: []
    }
  end

  # Merges overlapping intervals into distinct absences, then returns
  # `{absences_that_lasted_long_enough_to_matter, all_absences, total_seconds_away}`.
  defp away_stats([]), do: {0, 0, 0}

  defp away_stats(intervals) do
    merged =
      intervals
      |> Enum.sort()
      |> Enum.reduce([], fn
        {start_ms, end_ms}, [{prev_start, prev_end} | rest] when start_ms <= prev_end ->
          [{prev_start, max(prev_end, end_ms)} | rest]

        interval, acc ->
          [interval | acc]
      end)

    min_ms = Proctoring.thresholds().away_incident_min_seconds * 1000
    total_ms = merged |> Enum.map(fn {s, e} -> e - s end) |> Enum.sum()

    {Enum.count(merged, fn {s, e} -> e - s >= min_ms end), length(merged), div(total_ms, 1000)}
  end

  # A floor, never zero - `elapsed_minutes` is used as a division
  # denominator in `Athena.Engagement.Proctoring` (rates per minute), and
  # this same floor is what `snapshot/1` falls back to when no process has
  # started yet (nothing reported = zero elapsed time by definition, but
  # zero would make that division blow up).
  defp min_elapsed_minutes, do: 1 / 60

  defp paste_ratio(%{total_chars: 0}), do: 0.0
  defp paste_ratio(%{pasted_chars: pasted, total_chars: total}), do: pasted / total

  # The cohort baseline is built from exactly the same `Proctoring.rates/1`
  # the evaluation compares against, so the percentile is always
  # apples-to-apples (and rates are withheld while still too early in the
  # attempt to be stable - one switch at second 30 would read as 2/min).
  defp report_rates_to_exam_integrity_stats(state) do
    for {metric, value} <- Proctoring.rates(reading(state)) do
      ExamIntegrityStats.report_rate(
        state.cohort_id,
        state.block_id,
        state.submission_id,
        metric,
        value
      )
    end

    :ok
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
      right_click_attempt: 0,
      bulk_insert: 0,
      offline_period: 0,
      mouse_left: 0,
      fullscreen_exit: 0,
      large_paste: 0,
      split_screen: 0,
      paste_ratio: 0.0
    }
  end

  defp initial_typing do
    %{
      keys: 0,
      dwell_sum: 0.0,
      cv_sum: 0.0,
      pauses: 0,
      max_clean_run: 0,
      chars_typed: 0,
      chars_deleted: 0
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
