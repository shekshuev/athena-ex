defmodule Athena.Engagement.ProctoringMonitor do
  @moduledoc """
  Ephemeral, per-exam-attempt accumulator of academic-integrity signal
  counts (focus loss, PrintScreen, copy/cut attempts) - see
  `Athena.Engagement.Proctoring` for how these raw counts turn into a risk
  level. One process per submission id (the parent submission of one
  `quiz_exam`/`ticket_exam` attempt), started lazily by the first
  `report_events/2` call and stopped either explicitly by `finalize/1`
  (the exam was submitted) or by idle timeout (an abandoned attempt - a
  closed tab, a crash, ...).

  Deliberately pure in-memory and fed by direct casts from the exam
  LiveViews' own `engagement_batch` handler, not by a PubSub subscription
  like `Athena.Engagement.BlockStats` - there is nothing to bootstrap from
  the database (a fresh attempt has no prior signal), and nothing is
  written to the database until `finalize/1`. That's the whole point of
  accumulating here instead of writing a row per event during a live,
  timed exam.
  """

  use GenServer

  @registry Athena.Engagement.ProctoringMonitorRegistry
  @supervisor Athena.Engagement.ProctoringMonitorSupervisor

  @tracked_event_types [:tab_hidden, :printscreen_attempt, :copy_attempt, :cut_attempt]

  @type counts :: %{
          tab_hidden: non_neg_integer(),
          printscreen_attempt: non_neg_integer(),
          copy_attempt: non_neg_integer(),
          cut_attempt: non_neg_integer()
        }

  # Public API

  @doc "The event types this monitor accumulates - used by callers to filter a batch before forwarding."
  @spec tracked_event_types() :: [atom()]
  def tracked_event_types, do: @tracked_event_types

  @doc "Looks up (or lazily starts) the process for this submission and returns its pid."
  @spec get_or_start(binary()) :: {:ok, pid()}
  def get_or_start(submission_id) do
    case Registry.lookup(@registry, submission_id) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        case DynamicSupervisor.start_child(@supervisor, {__MODULE__, submission_id}) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
        end
    end
  end

  @doc """
  Fire-and-forget: casts already-normalized events into the attempt's
  counters. Callers should pre-filter to `tracked_event_types/0` (or pass
  a mixed batch - untracked types are simply ignored here).
  """
  @spec report_events(binary(), [map()]) :: :ok
  def report_events(_submission_id, []), do: :ok

  def report_events(submission_id, events) do
    {:ok, pid} = get_or_start(submission_id)
    GenServer.cast(pid, {:events, events})
  end

  @doc """
  Current counts, live. Returns all-zero counts (not an error) if no
  process is running - either nothing has happened yet, or the attempt
  already finalized.
  """
  @spec snapshot(binary()) :: counts()
  def snapshot(submission_id) do
    case Registry.lookup(@registry, submission_id) do
      [{pid, _}] -> GenServer.call(pid, :snapshot)
      [] -> initial_counts()
    end
  end

  @doc "Reads the final counts and stops the process. Idempotent - safe to call on an attempt with no process."
  @spec finalize(binary()) :: counts()
  def finalize(submission_id) do
    counts = snapshot(submission_id)

    case Registry.lookup(@registry, submission_id) do
      [{pid, _}] -> GenServer.stop(pid, :normal)
      [] -> :ok
    end

    counts
  end

  @doc false
  def child_spec(submission_id) do
    %{
      id: {__MODULE__, submission_id},
      start: {__MODULE__, :start_link, [submission_id]},
      restart: :temporary
    }
  end

  @doc false
  def start_link(submission_id) do
    GenServer.start_link(__MODULE__, submission_id,
      name: {:via, Registry, {@registry, submission_id}}
    )
  end

  # Server callbacks

  @impl true
  def init(submission_id) do
    schedule_idle_check()

    {:ok,
     %{submission_id: submission_id, counts: initial_counts(), last_event_at: DateTime.utc_now()}}
  end

  @impl true
  def handle_cast({:events, events}, state) do
    counts =
      Enum.reduce(events, state.counts, fn event, acc ->
        if event.event_type in @tracked_event_types do
          Map.update!(acc, event.event_type, &(&1 + 1))
        else
          acc
        end
      end)

    Phoenix.PubSub.broadcast(
      Athena.PubSub,
      "proctoring:#{state.submission_id}",
      {:proctoring_updated, state.submission_id, counts}
    )

    {:noreply, %{state | counts: counts, last_event_at: DateTime.utc_now()}}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, state.counts, state}
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

  defp initial_counts,
    do: %{tab_hidden: 0, printscreen_attempt: 0, copy_attempt: 0, cut_attempt: 0}

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
