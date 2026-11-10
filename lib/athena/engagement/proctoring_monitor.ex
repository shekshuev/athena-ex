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

  Accumulated in memory with periodic durable checkpoints, and fed by direct casts from the exam
  LiveViews' own `engagement_batch` handler (and, for the couple of
  signals the *server* originates - `answer_changed`, `code_run_attempt` -
  from `AthenaWeb.LearnLive.EngagementSignals`), not by a PubSub
  subscription like `Athena.Engagement.BlockStats` - there is nothing to
  bootstrap from raw events. Checkpoints preserve the aggregates across
  restarts without writing a row per event during a live, timed exam.

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

  alias Athena.Engagement.{ExamIntegrityStats, Proctoring, ProctoringCheckpoint}

  @registry Athena.Engagement.ProctoringMonitorRegistry
  @supervisor Athena.Engagement.ProctoringMonitorSupervisor

  @max_incidents 100
  @max_away_intervals 500
  @max_telemetry_number 1_000_000_000

  # Max plausible divergence between a client event's `occurred_at` and the
  # server's receipt time before it's flagged as a doctored/skewed clock.
  @max_clock_skew_ms 120_000

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
          max_connected_silence_seconds: non_neg_integer(),
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
    case lookup_monitor(submission_id) do
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
  Tells the attempt's monitor whether the exam tab is currently connected.
  A `true` (page mounted) starts the monitor if needed - we want it to know
  the tab is live even before the first telemetry arrives. A `false` (socket
  torn down: tab closed, navigation, network loss) is delivered only if a
  monitor is already running, so a disconnect at or after `finalize/1` can
  never resurrect a fresh, empty monitor for a finished attempt.
  """
  @spec connection(binary(), binary() | nil, binary(), boolean()) :: :ok
  def connection(submission_id, cohort_id, block_id, true) do
    {:ok, pid} = get_or_start(submission_id, cohort_id, block_id)
    # `self()` is the caller - the exam LiveView process. Each tab is a
    # distinct process, which is what makes concurrent-tab detection
    # server-authoritative (works across browsers/profiles, unlike the
    # client-side MultiTabGuard).
    GenServer.cast(pid, {:connection, self(), true})
  end

  def connection(submission_id, _cohort_id, _block_id, false) do
    ref = self()

    case lookup_monitor(submission_id) do
      [{pid, _}] -> GenServer.cast(pid, {:connection, ref, false})
      [] -> :ok
    end
  end

  @doc """
  Current counts and elapsed minutes, live. Returns an all-zero reading
  (not an error) if no process is running - either nothing has happened
  yet, or the attempt already finalized.
  """
  @spec snapshot(binary()) :: reading()
  def snapshot(submission_id) do
    case lookup_monitor(submission_id) do
      [{pid, _}] -> GenServer.call(pid, :snapshot)
      [] -> empty_reading()
    end
  end

  @doc "Reads the final reading and stops the process. Idempotent - safe to call on an attempt with no process."
  @spec finalize(binary()) :: reading()
  def finalize(submission_id) do
    # A timeout/restart may have stopped the process while leaving a checkpoint.
    if lookup_monitor(submission_id) == [] and
         not is_nil(ProctoringCheckpoint.load(submission_id)) do
      get_or_start(submission_id, nil, nil)
    end

    reading = snapshot(submission_id)

    case lookup_monitor(submission_id) do
      [{pid, _}] -> GenServer.stop(pid, :normal)
      [] -> :ok
    end

    # The final reading is persisted into `Submission.content` by the caller;
    # the live checkpoint is no longer needed.
    ProctoringCheckpoint.delete(submission_id)

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

    state = %{
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
      # Whether the exam tab is currently connected (fed by the exam
      # LiveView via `connection/4`). Lets a telemetry silence be told
      # apart from a plain network drop: silence while still connected is
      # the suspicious case, silence after a disconnect is just the network.
      connected: false,
      # Live exam sessions (distinct LiveView pids) for this attempt, for
      # server-side concurrent-tab detection; `connected` is derived from it.
      sessions: MapSet.new(),
      session_monitors: %{},
      concurrent_flagged: false,
      server_multi_tab_detected: 0,
      # Time of the last real (non-heartbeat) engagement event, for the
      # "channel alive but inert" check; `inert_flagged` dedups the incident.
      last_signal_at: now,
      inert_flagged: false,
      max_connected_silence_seconds: 0,
      incidents: [],
      away_intervals: [],
      last_away_ended_at: nil,
      mouse_away_ms: 0,
      typing: initial_typing(),
      tab_hidden: false
    }

    # Resume from the last durable checkpoint if this attempt was already
    # in progress before a restart/crash (see `restore_from_checkpoint/1`).
    {:ok, restore_from_checkpoint(state)}
  end

  @impl true
  def handle_cast({:events, events}, state) do
    # Stamp each event with the server's receipt time. From here on the
    # timeline is positioned by the server clock, not the client's
    # `occurred_at` (see `finished_at_ms/1`), so a doctored client clock
    # can't move absences around or decouple a paste from a preceding
    # absence. A large client/server divergence is itself recorded.
    received_at = DateTime.utc_now()
    events = Enum.map(events, &Map.put(&1, :received_at, received_at))

    state = note_activity(state)
    state = maybe_note_clock_skew(state, events, received_at)
    state = Enum.reduce(events, state, &apply_event/2)

    state = %{
      state
      | tab_hidden: Enum.reduce(events, state.tab_hidden, &apply_tab_hidden/2),
        # Real events arrived - the channel isn't inert; see
        # `detect_inert_channel/1`.
        last_signal_at: received_at,
        inert_flagged: false
    }

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
  def handle_cast({:connection, ref, connected?}, state) do
    # Close out the gap so far under the CURRENT flag, then update the live
    # session set. `connected` is derived from whether any session is live;
    # the set also drives concurrent-tab detection on the idle tick.
    state = note_activity(state)

    state =
      if connected? do
        monitors = Map.put_new_lazy(state.session_monitors, ref, fn -> Process.monitor(ref) end)
        %{state | sessions: MapSet.put(state.sessions, ref), session_monitors: monitors}
      else
        remove_session(state, ref)
      end

    {:noreply, detect_concurrent_sessions(state)}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    state = state |> detect_concurrent_sessions() |> detect_inert_channel()
    {:reply, reading(state), state}
  end

  @impl true
  def handle_info({:DOWN, monitor_ref, :process, pid, _reason}, state) do
    if Map.get(state.session_monitors, pid) == monitor_ref do
      state = state |> note_activity() |> remove_session(pid) |> detect_concurrent_sessions()
      broadcast_updated(state)
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(:check_idle, state) do
    idle_for_ms = DateTime.diff(DateTime.utc_now(), state.last_event_at, :millisecond)

    if idle_for_ms >= idle_timeout_seconds() * 1000 do
      persist_checkpoint(state)
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

      # Periodic durable checkpoint (this tick runs ~once a minute in prod),
      # so a restart/crash loses at most the last interval, not the whole
      # attempt. Best-effort - `persist_checkpoint/1` never raises.
      state = detect_concurrent_sessions(state)
      state = detect_inert_channel(state)
      persist_checkpoint(state)
      schedule_idle_check()
      {:noreply, state}
    end
  end

  defp remove_session(state, pid) do
    {monitor_ref, monitors} = Map.pop(state.session_monitors, pid)
    if monitor_ref, do: Process.demonitor(monitor_ref, [:flush])
    %{state | sessions: MapSet.delete(state.sessions, pid), session_monitors: monitors}
  end

  # Registry cleanup is asynchronous: a stopped process can still have an
  # entry briefly. Never hand that stale pid back to a caller after restart.
  defp lookup_monitor(submission_id) do
    @registry
    |> Registry.lookup(submission_id)
    |> Enum.filter(fn {pid, _} -> Process.alive?(pid) end)
  end

  # Internals

  # Only a paste that follows a recent absence (left the page, came back,
  # pasted) is treated as suspicious - see `recent_away?/2`. A paste with no
  # absence nearby is far more likely a student moving their own answer
  # between questions in the same attempt (a common, legitimate way to save
  # time) than anything fetched from outside the exam, so it is tracked
  # (`max_paste_chars`, for display) but does not feed `large_paste` or the
  # `paste_ratio` behavioral signal - neither should charge a student points
  # for copying their own work.
  defp apply_event(%{event_type: :paste_detected} = event, state) do
    payload = payload(event)
    total = int(payload["total_chars"])
    pasted = min(int(payload["pasted_chars"]), total)
    state = %{state | max_paste_chars: max(state.max_paste_chars, pasted)}

    if recent_away?(state, event) do
      paste_totals = %{
        state.paste_totals
        | pasted_chars: state.paste_totals.pasted_chars + pasted,
          total_chars: state.paste_totals.total_chars + total
      }

      counts =
        if pasted >= Proctoring.thresholds().large_paste_chars,
          do: Map.update!(state.counts, :large_paste, &(&1 + 1)),
          else: state.counts

      %{state | paste_totals: paste_totals, counts: counts}
    else
      state
    end
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
    seconds = div(sane_duration_ms(event, state), 1000)

    state
    |> bump(:offline_period)
    |> Map.update!(:max_offline_seconds, &max(&1, seconds))
  end

  defp apply_event(%{event_type: :mouse_left} = event, state) do
    state
    |> bump(:mouse_left)
    |> Map.update!(:mouse_away_ms, &(&1 + sane_duration_ms(event, state)))
  end

  defp apply_event(%{event_type: type}, state) when type in @counted_event_types,
    do: bump(state, type)

  defp apply_event(_event, state), do: state

  defp bump(state, key), do: %{state | counts: Map.update!(state.counts, key, &(&1 + 1))}

  # The interval ends when the server received the "back" event and began
  # `duration_ms` earlier; overlapping intervals (Alt+Tab fires both
  # `window_focus` and, if the browser got fully covered, `tab_visible`)
  # are merged on read, so one absence is never counted twice. Positioned
  # by server receipt time and clamped to the attempt's own elapsed time.
  defp add_away_interval(state, event) do
    duration_ms = sane_duration_ms(event, state)

    if duration_ms > 0 do
      finished_ms = finished_at_ms(event)
      interval = {finished_ms - duration_ms, finished_ms}

      %{
        state
        | away_intervals: Enum.take([interval | state.away_intervals], @max_away_intervals),
          last_away_ended_at: finished_ms
      }
    else
      state
    end
  end

  # Server receipt time wins over the client's `occurred_at` so the client
  # clock can't position events on the timeline; `occurred_at` is only a
  # fallback for events that reach the monitor without a server stamp.
  defp finished_at_ms(%{received_at: %DateTime{} = at}), do: DateTime.to_unix(at, :millisecond)
  defp finished_at_ms(%{occurred_at: %DateTime{} = at}), do: DateTime.to_unix(at, :millisecond)
  defp finished_at_ms(_event), do: System.os_time(:millisecond)

  # Was `event` (a paste) preceded closely enough by the student last
  # returning from being away (tab/window/fullscreen) to plausibly be its
  # source? See `apply_event/2` for `:paste_detected` for why this gates
  # whether a paste counts as suspicious at all.
  defp recent_away?(%{last_away_ended_at: nil}, _event), do: false

  defp recent_away?(%{last_away_ended_at: ended_ms}, event) do
    gap = finished_at_ms(event) - ended_ms
    gap >= 0 and gap <= Proctoring.thresholds().paste_away_window_seconds * 1000
  end

  defp payload(%{payload: payload}) when is_map(payload), do: payload
  defp payload(_event), do: %{}

  defp int(value) when is_integer(value) and value > 0, do: min(value, @max_telemetry_number)
  defp int(value) when is_float(value) and value > 0, do: trunc(min(value, @max_telemetry_number))
  defp int(_value), do: 0

  defp num(value) when is_number(value) and value > 0,
    do: min(value, @max_telemetry_number) * 1.0

  defp num(_value), do: 0.0

  # Client-reported durations can't exceed how long this attempt has
  # actually been running on the server - clamp to [0, elapsed] so a
  # garbage or inflated `duration_ms` can't skew the aggregates. (Server
  # silence tracking, p1/p2, independently catches under-reported absences.)
  defp sane_duration_ms(event, state) do
    elapsed_ms = max(DateTime.diff(DateTime.utc_now(), state.started_at, :millisecond), 0)

    event
    |> payload()
    |> Map.get("duration_ms")
    |> int()
    |> min(elapsed_ms)
  end

  # Records at most one `clock_skew` incident per attempt if any event's
  # client `occurred_at` is implausibly far from when the server received
  # it - a sign of a tampered clock. Incidents are a scarce capped list, so
  # only the first is kept; the numeric risk score is left untouched.
  defp maybe_note_clock_skew(state, events, received_at) do
    skew = max_skew_ms(events, received_at)
    already? = Enum.any?(state.incidents, &(&1["type"] == "clock_skew"))

    if skew >= @max_clock_skew_ms and not already? do
      incident = %{
        "type" => "clock_skew",
        "at" => DateTime.to_iso8601(received_at),
        "skew_ms" => skew
      }

      %{state | incidents: Enum.take(state.incidents ++ [incident], -@max_incidents)}
    else
      state
    end
  end

  defp max_skew_ms(events, received_at) do
    recv_ms = DateTime.to_unix(received_at, :millisecond)

    Enum.reduce(events, 0, fn
      %{occurred_at: %DateTime{} = at}, acc ->
        max(acc, abs(recv_ms - DateTime.to_unix(at, :millisecond)))

      _event, acc ->
        acc
    end)
  end

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
    # A gap that elapsed while the tab was still connected is the suspicious
    # kind (telemetry suppressed on a live page); a gap after a disconnect is
    # just the network. `current_silence_seconds/2` already returns 0 while
    # the tab is legitimately backgrounded, so that case never counts here.
    connected_gap = if state.connected, do: gap, else: 0

    incidents =
      if gap >= Proctoring.thresholds().heartbeat_silence_yellow_threshold_seconds do
        incident = %{
          "type" => if(state.connected, do: "silence_connected", else: "silence"),
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
        max_connected_silence_seconds: max(state.max_connected_silence_seconds, connected_gap),
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
    # The still-open gap counts as connected-silence only if the tab is
    # connected right now (and not backgrounded, which already zeroes it).
    connected_silence = if state.connected, do: silence_seconds, else: 0
    {away_incidents, away_count, away_total_seconds} = away_stats(state.away_intervals)

    %{
      counts: Map.put(state.counts, :paste_ratio, paste_ratio(state.paste_totals)),
      server_multi_tab_detected: state.server_multi_tab_detected,
      elapsed_minutes: elapsed_minutes,
      silence_seconds: silence_seconds,
      max_silence_seconds: max(state.max_silence_seconds, silence_seconds),
      max_offline_seconds: state.max_offline_seconds,
      max_connected_silence_seconds: max(state.max_connected_silence_seconds, connected_silence),
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
      max_connected_silence_seconds: 0,
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

  # --- Durable checkpointing (restart / crash resilience) -------------------

  # The accumulated signal totals worth surviving a restart. Deliberately
  # excludes `last_event_at`/`connected` (transient, re-established on
  # resume) and the ids (known from the child spec).
  @checkpointable_keys [
    :started_at,
    :server_multi_tab_detected,
    :counts,
    :paste_totals,
    :max_paste_chars,
    :max_silence_seconds,
    :max_offline_seconds,
    :max_connected_silence_seconds,
    :incidents,
    :away_intervals,
    :last_away_ended_at,
    :mouse_away_ms,
    :typing,
    :tab_hidden
  ]

  # Overlay the last durable checkpoint onto a fresh state after a node
  # restart or monitor crash. `last_event_at` is reset to now so the
  # downtime is never charged as silence, and `connected` stays false until
  # the exam LiveView reports in again. A missing or unreadable checkpoint
  # leaves the fresh state untouched, so this can never crash init.
  defp restore_from_checkpoint(state) do
    case ProctoringCheckpoint.load(state.submission_id) do
      %{version: 1, state: saved} when is_map(saved) ->
        if valid_checkpoint?(saved, state) do
          # Visibility is session-local; a reloaded page starts visible.
          state
          |> Map.merge(Map.take(saved, @checkpointable_keys))
          |> Map.put(:tab_hidden, false)
        else
          state
        end

      _ ->
        state
    end
  end

  defp persist_checkpoint(state) do
    ProctoringCheckpoint.save(state.submission_id, %{
      version: 1,
      state: Map.take(state, @checkpointable_keys)
    })
  end

  defp valid_checkpoint?(saved, fresh) do
    Enum.all?(@checkpointable_keys, fn key ->
      Map.has_key?(saved, key) and valid_checkpoint_value?(key, saved[key], fresh[key])
    end)
  rescue
    _ -> false
  end

  defp valid_checkpoint_value?(:started_at, %DateTime{} = at, _),
    do: DateTime.compare(at, DateTime.utc_now()) != :gt

  defp valid_checkpoint_value?(:started_at, _, _), do: false

  defp valid_checkpoint_value?(:incidents, value, _),
    do: is_list(value) and length(value) <= @max_incidents and Enum.all?(value, &is_map/1)

  defp valid_checkpoint_value?(:away_intervals, value, _) when is_list(value) do
    length(value) <= @max_away_intervals and
      Enum.all?(value, fn
        {a, b} when is_integer(a) and is_integer(b) -> a <= b
        _ -> false
      end)
  end

  defp valid_checkpoint_value?(:last_away_ended_at, value, _),
    do: is_nil(value) or is_integer(value)

  defp valid_checkpoint_value?(_, value, template) when is_map(template) and is_map(value) do
    Map.keys(value) == Map.keys(template) and
      Enum.all?(template, fn {key, default} ->
        valid_checkpoint_value?(key, value[key], default)
      end)
  end

  defp valid_checkpoint_value?(_, value, template) when is_boolean(template),
    do: is_boolean(value)

  defp valid_checkpoint_value?(_, value, template) when is_integer(template),
    do: is_integer(value) and value >= 0

  defp valid_checkpoint_value?(_, value, template) when is_float(template),
    do: is_number(value) and value >= 0

  defp valid_checkpoint_value?(_, _, _), do: false

  # Server-authoritative concurrent-session check, run on the idle tick. Two
  # or more live exam sessions (distinct LiveView pids) for one attempt means
  # it is open in more than one place - a second browser, profile or
  # incognito window the client-side MultiTabGuard cannot see. Dead pids are
  # pruned first, so a reconnect's brief overlap (old process not yet reaped)
  # never trips it; only concurrency still present at this tick is flagged,
  # once, feeding the existing `multi_tab_detected` signal plus a
  # `concurrent_session` incident on the teacher's timeline.
  defp detect_concurrent_sessions(state) do
    alive =
      state.sessions
      |> Enum.filter(fn pid -> node(pid) == node() and Process.alive?(pid) end)
      |> MapSet.new()

    state = %{state | sessions: alive, connected: MapSet.size(alive) > 0}

    cond do
      MapSet.size(alive) > 1 and not state.concurrent_flagged ->
        incident = %{
          "type" => "concurrent_session",
          "at" => DateTime.to_iso8601(DateTime.utc_now()),
          "sessions" => MapSet.size(alive)
        }

        %{
          state
          | concurrent_flagged: true,
            server_multi_tab_detected: state.server_multi_tab_detected + 1,
            counts: Map.update!(state.counts, :multi_tab_detected, &(&1 + 1)),
            incidents: Enum.take(state.incidents ++ [incident], -@max_incidents)
        }

      MapSet.size(alive) <= 1 ->
        %{state | concurrent_flagged: false}

      true ->
        state
    end
  end

  # "Channel alive but inert": heartbeats are still arriving (the socket is
  # live) but no real engagement event has come in for a long stretch - the
  # shape left when a student suppresses the individual listeners yet keeps
  # the heartbeat alive to pass the liveness gate. Review signal only (an
  # `inert_channel` incident), never scored: a deep reading pause with no
  # typing looks the same, so this informs a human, it does not flag red.
  defp detect_inert_channel(state) do
    now = DateTime.utc_now()

    heartbeats_current? =
      not state.tab_hidden and
        DateTime.diff(now, state.last_event_at, :second) <= inert_heartbeat_recent_seconds()

    signal_gap = DateTime.diff(now, state.last_signal_at, :second)

    cond do
      state.connected and heartbeats_current? and signal_gap >= inert_channel_seconds() and
          not state.inert_flagged ->
        incident = %{
          "type" => "inert_channel",
          "at" => DateTime.to_iso8601(now),
          "seconds" => signal_gap
        }

        %{
          state
          | inert_flagged: true,
            incidents: Enum.take(state.incidents ++ [incident], -@max_incidents)
        }

      signal_gap < inert_channel_seconds() ->
        %{state | inert_flagged: false}

      true ->
        state
    end
  end

  defp config, do: Application.get_env(:athena, Athena.Engagement, [])

  # How long the channel may show only heartbeats (no real events) before an
  # `inert_channel` incident is recorded. Generous by default - a long
  # reading pause with no typing is innocent and looks the same.
  defp inert_channel_seconds do
    Keyword.get(config(), :exam_inert_channel_seconds, 300)
  end

  # How recent the last activity (heartbeat included) must be to count the
  # channel as still alive - a couple of missed 10s heartbeats of slack.
  defp inert_heartbeat_recent_seconds do
    Keyword.get(config(), :exam_inert_heartbeat_recent_seconds, 30)
  end

  defp idle_timeout_seconds do
    Keyword.get(config(), :proctoring_monitor_idle_timeout_minutes, 180) * 60
  end
end
