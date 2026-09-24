defmodule Athena.Engagement.ExamIntegrityStats do
  @moduledoc """
  Cohort-relative baseline for a handful of exam-attempt *rate* metrics
  (per-minute focus loss, per-minute answer changes, paste ratio) - lets
  `Athena.Engagement.Proctoring` ask "is this student's behavior a real
  outlier compared to everyone else taking this same exam right now", not
  just "is this raw count bigger than some fixed number". A flat absolute
  threshold would flag an anxious student who revises their answer a lot
  exactly the same way it would flag someone who actually cheated - the
  point of this module is to only flag behavior that is unusual *relative
  to peers taking the same exam under the same time pressure*, so a
  generally-hard or ambiguous question that makes everyone hesitate more
  doesn't get anyone singled out.

  One process per `{cohort_id, exam_block_id}`. Unlike `Athena.Engagement.
  BlockStats` (which folds an append-only *event* stream via Welford's
  online algorithm - each dwell happens once, forever, so incremental
  mean/variance makes sense), each student's rate here is a *live,
  replaceable* current value that keeps changing for the whole length of
  their attempt. State is therefore a plain `%{submission_id => value}` map
  per metric, with the same submission's entry simply overwritten as new
  reports arrive; mean/stddev are recomputed from that small map on every
  read. Cohort sizes here are small (dozens, not millions), so this is
  cheap - an incremental algorithm isn't just unnecessary here, it would be
  wrong: Welford would double (or triple, or...) count the same student's
  earlier and later rates as if they were different people.
  """

  use GenServer

  @registry Athena.Engagement.ExamIntegrityStatsRegistry
  @supervisor Athena.Engagement.ExamIntegrityStatsSupervisor

  @type metric :: :tab_hidden_per_minute | :answer_changed_per_minute | :paste_ratio

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
  Approximate percentile rank (0-100) of `value` within the cohort's
  current distribution for `metric`, or `nil` when fewer than
  `min_sample_size_for_percentile` other submissions have reported a value
  yet - not enough peers to say anything about "relative to the group".
  """
  @spec percentile_rank(binary() | nil, binary(), metric(), number()) :: float() | nil
  def percentile_rank(cohort_id, block_id, metric, value) do
    {:ok, pid} = get_or_start(cohort_id, block_id)
    GenServer.call(pid, {:percentile_rank, metric, value})
  end

  @doc """
  Drops one submission's contribution to every tracked metric - called
  once its attempt finalizes, so a finished student's now-frozen rate
  doesn't keep skewing the live baseline for everyone still taking the
  exam (or, hours later, for a different sitting of the same exam).
  """
  @spec forget(binary() | nil, binary(), binary()) :: :ok
  def forget(cohort_id, block_id, submission_id) do
    case Registry.lookup(@registry, {cohort_id, block_id}) do
      [{pid, _}] -> GenServer.cast(pid, {:forget, submission_id})
      [] -> :ok
    end
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

  def handle_cast({:forget, submission_id}, state) do
    per_metric =
      Map.new(state.per_metric, fn {metric, values} ->
        {metric, Map.delete(values, submission_id)}
      end)

    {:noreply, %{state | per_metric: per_metric}}
  end

  @impl true
  def handle_call({:percentile_rank, metric, value}, _from, state) do
    peer_values = state.per_metric |> Map.get(metric, %{}) |> Map.values()
    {:reply, percentile_rank_for(peer_values, value), state}
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

  defp percentile_rank_for(peer_values, value) do
    if length(peer_values) < min_sample_size() do
      nil
    else
      n = length(peer_values)
      mean = Enum.sum(peer_values) / n

      variance =
        if n < 2 do
          0.0
        else
          peer_values |> Enum.map(&:math.pow(&1 - mean, 2)) |> Enum.sum() |> Kernel./(n - 1)
        end

      stddev = :math.sqrt(variance)

      # Summing many floats accumulates tiny rounding noise, so a cohort
      # that's genuinely all-identical rarely lands on an exact `0.0`
      # variance - comparing for exact equality would let that noise get
      # amplified into a wild z-score once divided into. A small epsilon
      # treats "effectively no spread" as no spread.
      cond do
        stddev < 1.0e-9 and value > mean + 1.0e-9 -> 100.0
        stddev < 1.0e-9 -> 50.0
        true -> zscore_to_percentile((value - mean) / stddev)
      end
    end
  end

  defp zscore_to_percentile(z), do: normal_cdf(z) * 100

  defp normal_cdf(x), do: 0.5 * (1 + erf(x / :math.sqrt(2)))

  # Abramowitz & Stegun 7.1.26 approximation of the error function,
  # accurate to ~1.5e-7 - good enough for "roughly where does this land in
  # a normal-ish distribution", not a claim of exact normality, and avoids
  # pulling in a stats library for this one lookup.
  defp erf(x) do
    sign = if x < 0, do: -1, else: 1
    x = abs(x)

    a1 = 0.254829592
    a2 = -0.284496736
    a3 = 1.421413741
    a4 = -1.453152027
    a5 = 1.061405429
    p = 0.3275911

    t = 1 / (1 + p * x)
    y = 1 - ((((a5 * t + a4) * t + a3) * t + a2) * t + a1) * t * :math.exp(-x * x)

    sign * y
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
  defp min_sample_size, do: Keyword.get(config(), :min_sample_size_for_percentile, 15)

  defp idle_timeout_seconds do
    Keyword.get(config(), :proctoring_monitor_idle_timeout_minutes, 180) * 60
  end
end
