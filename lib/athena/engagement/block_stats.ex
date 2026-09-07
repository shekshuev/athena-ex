defmodule Athena.Engagement.BlockStats do
  @moduledoc """
  A warm, incrementally-updated running statistic for one `{cohort_id,
  block_id}` pair - the dwell-time distribution students have produced on
  that block so far.

  One process per pair, started lazily on first use and stopped again after
  a period of inactivity. On start it bootstraps once from the database
  (a single aggregate read of existing events), then updates itself purely
  from the `"engagement:\#{cohort_id}:\#{block_id}"` PubSub stream - no
  process here ever issues a second query per incoming event. This is what
  lets both the student-facing nudge decision (`Athena.Engagement.
  evaluate_nudge/5`, reads a percentile rank) and the teacher dashboard (a
  live aggregate view) stay cheap under load: both just read already-computed
  in-memory state.

  Dwell time is derived by pairing `viewport_enter`/`viewport_exit` events
  within one session - the mean/variance are tracked online (Welford's
  algorithm, so no per-value history needs to be kept), and a coarse
  fixed-width histogram gives an approximate percentile rank, which is all
  a "read faster/slower than peers" decision needs (not an exact order
  statistic).
  """

  use GenServer

  alias Athena.Engagement.Events

  @registry Athena.Engagement.BlockStatsRegistry
  @supervisor Athena.Engagement.BlockStatsSupervisor

  @type t :: %{
          cohort_id: binary() | nil,
          block_id: binary(),
          n: non_neg_integer(),
          mean: float(),
          m2: float(),
          bucket_width: float(),
          buckets: %{non_neg_integer() => non_neg_integer()},
          pending_enters: %{binary() => DateTime.t()},
          last_event_at: DateTime.t()
        }

  # Public API

  @doc """
  Looks up (or lazily starts) the process for this pair and returns its pid.
  """
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

  @doc """
  Current running statistics for the pair: sample size, mean, standard
  deviation (dwell seconds). `n: 0` means no dwell samples observed yet.
  """
  @spec snapshot(binary() | nil, binary()) :: %{
          n: non_neg_integer(),
          mean: float(),
          stddev: float()
        }
  def snapshot(cohort_id, block_id) do
    {:ok, pid} = get_or_start(cohort_id, block_id)
    GenServer.call(pid, :snapshot)
  end

  @doc """
  Approximate percentile (0-100) of `seconds` within the pair's observed
  dwell-time distribution, or `nil` if there is no data yet.
  """
  @spec percentile_rank(binary() | nil, binary(), number()) :: float() | nil
  def percentile_rank(cohort_id, block_id, seconds) do
    {:ok, pid} = get_or_start(cohort_id, block_id)
    GenServer.call(pid, {:percentile_rank, seconds})
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
    Phoenix.PubSub.subscribe(Athena.PubSub, "engagement:#{cohort_id}:#{block_id}")

    dwells =
      [block_id]
      |> Events.list_events_for_scope(cohort_id)
      |> Events.pair_viewport_dwells()
      |> Enum.map(fn {_session_id, _account_id, dwell_seconds} -> dwell_seconds end)

    state =
      Enum.reduce(dwells, initial_state(cohort_id, block_id), &record_dwell(&2, &1))

    schedule_idle_check()

    {:ok, state}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, %{n: state.n, mean: state.mean, stddev: stddev(state)}, state}
  end

  def handle_call({:percentile_rank, seconds}, _from, state) do
    {:reply, percentile_rank_for(state, seconds), state}
  end

  @impl true
  def handle_info({:engagement_event, %{event_type: :viewport_enter} = event}, state) do
    pending = Map.put(state.pending_enters, event.session_id, event.occurred_at)
    {:noreply, %{state | pending_enters: pending, last_event_at: DateTime.utc_now()}}
  end

  def handle_info({:engagement_event, %{event_type: :viewport_exit} = event}, state) do
    case Map.pop(state.pending_enters, event.session_id) do
      {nil, _pending} ->
        {:noreply, %{state | last_event_at: DateTime.utc_now()}}

      {entered_at, pending} ->
        dwell = max(DateTime.diff(event.occurred_at, entered_at, :second), 0)

        new_state =
          %{state | pending_enters: pending}
          |> record_dwell(dwell)
          |> Map.put(:last_event_at, DateTime.utc_now())

        {:noreply, new_state}
    end
  end

  def handle_info({:engagement_event, _other}, state) do
    {:noreply, %{state | last_event_at: DateTime.utc_now()}}
  end

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

  defp initial_state(cohort_id, block_id) do
    %{
      cohort_id: cohort_id,
      block_id: block_id,
      n: 0,
      mean: 0.0,
      m2: 0.0,
      bucket_width: histogram_max_seconds() / histogram_buckets(),
      buckets: %{},
      pending_enters: %{},
      last_event_at: DateTime.utc_now()
    }
  end

  # Welford's online algorithm - mean/variance without keeping every sample.
  defp record_dwell(state, dwell_seconds) do
    n = state.n + 1
    delta = dwell_seconds - state.mean
    mean = state.mean + delta / n
    delta2 = dwell_seconds - mean
    m2 = state.m2 + delta * delta2

    bucket = bucket_index(state, dwell_seconds)
    buckets = Map.update(state.buckets, bucket, 1, &(&1 + 1))

    %{state | n: n, mean: mean, m2: m2, buckets: buckets}
  end

  defp stddev(%{n: n}) when n < 2, do: 0.0
  defp stddev(%{n: n, m2: m2}), do: :math.sqrt(m2 / (n - 1))

  defp bucket_index(state, seconds) do
    max_bucket = histogram_buckets() - 1
    index = trunc(seconds / state.bucket_width)
    min(max(index, 0), max_bucket)
  end

  defp percentile_rank_for(%{n: 0}, _seconds), do: nil

  defp percentile_rank_for(state, seconds) do
    target_bucket = bucket_index(state, seconds)

    below =
      state.buckets
      |> Enum.filter(fn {bucket, _count} -> bucket < target_bucket end)
      |> Enum.map(fn {_bucket, count} -> count end)
      |> Enum.sum()

    in_bucket = Map.get(state.buckets, target_bucket, 0)

    # Linear interpolation of where `seconds` falls within its own bucket,
    # so the estimate isn't just a step function across bucket boundaries.
    bucket_start = target_bucket * state.bucket_width
    fraction_in_bucket = min(max((seconds - bucket_start) / state.bucket_width, 0.0), 1.0)

    (below + in_bucket * fraction_in_bucket) / state.n * 100
  end

  # Checks at most once a minute in production (idle_timeout defaults to 30
  # minutes), but scales down with a short configured timeout so tests that
  # override `block_stats_idle_timeout_minutes` don't have to wait a full
  # minute for the first check.
  defp schedule_idle_check do
    delay_ms = (idle_timeout_seconds() * 1000) |> min(:timer.minutes(1)) |> max(50) |> trunc()
    Process.send_after(self(), :check_idle, delay_ms)
  end

  defp config, do: Application.get_env(:athena, Athena.Engagement, [])
  defp histogram_buckets, do: Keyword.get(config(), :histogram_buckets, 10)
  defp histogram_max_seconds, do: Keyword.get(config(), :histogram_max_seconds, 1200)

  defp idle_timeout_seconds do
    Keyword.get(config(), :block_stats_idle_timeout_minutes, 30) * 60
  end
end
