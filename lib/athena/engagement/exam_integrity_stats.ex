defmodule Athena.Engagement.ExamIntegrityStats do
  @moduledoc """
  Group baseline for a handful of exam-attempt *rate* metrics (per-minute
  focus loss, per-minute answer changes, paste ratio, ...) - lets
  `Athena.Engagement.Proctoring` ask "is this student's behavior unusual
  compared to everyone else sitting this same exam", not just "is this raw
  count bigger than some fixed number". A flat threshold would flag an
  anxious student who revises their answer a lot exactly the same way it
  would flag someone who actually cheated; the group tells us what is normal
  *for this exam under this time pressure*.

  What the baseline is: for one student, the **median** of everybody else's
  value and a robust spread (scaled median absolute deviation). Medians, not
  means and z-scores: counts of events are heavily skewed (most students
  have zero, a few have a lot), and a normal-distribution assumption is
  both wrong for that and meaningless on a group of five. The baseline is
  usable from just two other students; how much to trust it for a small
  group is `Athena.Engagement.Proctoring`'s call, not this module's.

  Everyone who has reported a value stays in the baseline for as long as
  the exam's process lives - **including students who already finished**. A
  group's size must not depend on who happened to hand in first, otherwise
  the same behaviour would be judged differently depending on submission
  order and the last student to finish would always be judged alone.

  One process per `{cohort_id, exam_block_id}`. Unlike `Athena.Engagement.
  BlockStats` (which folds an append-only *event* stream), each student's
  rate here is a *live, replaceable* current value that keeps changing for
  the whole length of their attempt: state is a plain `%{submission_id =>
  value}` map per metric, the same submission's entry simply overwritten as
  new reports arrive, and the baseline is recomputed from that small map on
  every read. Cohort sizes are small (dozens), so this is cheap.
  """

  use GenServer

  @registry Athena.Engagement.ExamIntegrityStatsRegistry
  @supervisor Athena.Engagement.ExamIntegrityStatsSupervisor

  # Scales the median absolute deviation to be comparable with a standard
  # deviation for roughly normal data.
  @mad_scale 1.4826

  @type metric ::
          :tab_hidden_per_minute
          | :answer_changed_per_minute
          | :paste_ratio
          | :right_click_per_minute
          | :mouse_away_seconds_per_minute

  @type baseline :: %{n: non_neg_integer(), median: float(), spread: float()}

  # Public API

  @doc "Looks up (or lazily starts) the process for this exam and returns its pid."
  @spec get_or_start(binary() | nil, binary()) :: {:ok, pid()}
  def get_or_start(cohort_id, block_id) do
    case Registry.lookup(@registry, {cohort_id, block_id}) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        case DynamicSupervisor.start_child(@supervisor, {__MODULE__, {cohort_id, block_id}}) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
        end
    end
  end

  @doc "Replaces this submission's current value for `metric` in the cohort's live distribution."
  @spec report_rate(binary() | nil, binary(), binary(), metric(), number()) :: :ok
  def report_rate(cohort_id, block_id, submission_id, metric, value) when is_number(value) do
    {:ok, pid} = get_or_start(cohort_id, block_id)
    GenServer.cast(pid, {:report, submission_id, metric, value})
  end

  def report_rate(_cohort_id, _block_id, _submission_id, _metric, _value), do: :ok

  @doc """
  The baseline of every metric as seen by one student: the median and
  robust spread of everybody *else's* value, and how many others that is
  (`n`). `except_submission_id` is left out so a student is never compared
  with themselves; pass `nil` to include everybody.

  A metric nobody else has reported yet is `%{n: 0, median: 0.0, spread:
  0.0}` - callers decide from `n` whether that is enough to compare against.
  """
  @spec baselines(binary() | nil, binary(), binary() | nil) :: %{metric() => baseline()}
  def baselines(cohort_id, block_id, except_submission_id) do
    {:ok, pid} = get_or_start(cohort_id, block_id)
    GenServer.call(pid, {:baselines, except_submission_id})
  end

  @doc false
  def child_spec({cohort_id, block_id}) do
    %{
      id: {__MODULE__, cohort_id, block_id},
      start: {__MODULE__, :start_link, [{cohort_id, block_id}]},
      restart: :temporary
    }
  end

  @doc false
  def start_link({cohort_id, block_id}) do
    GenServer.start_link(__MODULE__, {cohort_id, block_id},
      name: {:via, Registry, {@registry, {cohort_id, block_id}}}
    )
  end

  # Server callbacks

  @impl true
  def init({cohort_id, block_id}) do
    schedule_idle_check()

    {:ok,
     %{
       cohort_id: cohort_id,
       block_id: block_id,
       per_metric: %{},
       last_event_at: DateTime.utc_now()
     }}
  end

  @impl true
  def handle_cast({:report, submission_id, metric, value}, state) do
    values = Map.get(state.per_metric, metric, %{})
    per_metric = Map.put(state.per_metric, metric, Map.put(values, submission_id, value))

    {:noreply, %{state | per_metric: per_metric, last_event_at: DateTime.utc_now()}}
  end

  @impl true
  def handle_call({:baselines, except_submission_id}, _from, state) do
    baselines =
      Map.new(state.per_metric, fn {metric, values} ->
        others = values |> Map.delete(except_submission_id) |> Map.values()
        {metric, baseline_of(others)}
      end)

    {:reply, baselines, state}
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

  defp baseline_of([]), do: %{n: 0, median: 0.0, spread: 0.0}

  defp baseline_of(values) do
    median = median(values)
    mad = values |> Enum.map(&abs(&1 - median)) |> median()

    %{n: length(values), median: median, spread: mad * @mad_scale}
  end

  defp median(values) do
    sorted = Enum.sort(values)
    n = length(sorted)
    mid = div(n, 2)

    if rem(n, 2) == 1,
      do: Enum.at(sorted, mid) * 1.0,
      else: (Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2
  end

  # Checked at most once a minute in production, scales down with a short
  # configured timeout so tests don't have to wait a full minute for the
  # first check. Same generous default as `ProctoringMonitor` - an exam
  # attempt can legitimately sit open for as long as the block's
  # configured time limit.
  defp schedule_idle_check do
    delay_ms = (idle_timeout_seconds() * 1000) |> min(:timer.minutes(1)) |> max(50) |> trunc()
    Process.send_after(self(), :check_idle, delay_ms)
  end

  defp config, do: Application.get_env(:athena, Athena.Engagement, [])

  defp idle_timeout_seconds do
    Keyword.get(config(), :proctoring_monitor_idle_timeout_minutes, 180) * 60
  end
end
