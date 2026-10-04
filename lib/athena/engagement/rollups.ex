defmodule Athena.Engagement.Rollups do
  @moduledoc """
  Daily pre-aggregates of `engagement_events` (`Athena.Engagement.Rollup`):
  one row per (cohort, student, block, app-timezone day), each an
  `Athena.Engagement.Accumulator` stored column by column.

  ## Writing

  `process_new_events/1` (run every few minutes by
  `Athena.Engagement.Workers.RollupWorker`) walks new events in insertion
  order from a stored cursor, works out which (cohort, section, day)
  buckets they touch, and *recomputes* those buckets from raw events - not
  incrementally - so late or out-of-order events (an offline client
  flushing yesterday's batch) are always folded in correctly. Whole
  sections are recomputed because backtracking compares blocks within a
  section. Events without a cohort are skipped: no dashboard reads them.

  The cursor is an insertion time, and every pass re-reads the last
  minute before it as well. Insertion times are neither unique nor
  committed in order (two requests in the same second, a transaction that
  commits a moment after a later one), so a strict "after the cursor" scan
  could skip an event forever; recomputing is idempotent, so re-reading a
  minute of events is harmless.

  ## Reading

  Any window of days is a plain `SUM ... GROUP BY` over the rows
  (`account_block_totals/4`, `active_students_by_day/4`, `hour_matrix/4`).
  Callers combine past days from here with today's raw events (see
  `Athena.Engagement.Metrics`), and fall back to raw events entirely while
  `ready?/0` is false (rollups never built, or the worker is far behind).
  """

  import Ecto.Query

  alias Athena.{Repo, TimeZones}
  alias Athena.Content.Block
  alias Athena.Engagement.{Accumulator, DashboardCache, Event, Rollup, RollupCursor}

  @cursor "engagement_rollups"
  @default_batch_size 10_000
  @default_max_batches 50
  @max_lag_seconds 15 * 60
  @overlap_seconds 60

  @doc """
  Whether past days can be read from rollups: the worker has run at least
  once and no event older than #{div(@max_lag_seconds, 60)} minutes is
  still waiting to be folded in.
  """
  @spec ready?() :: boolean()
  def ready? do
    case Repo.get(RollupCursor, @cursor) do
      nil ->
        false

      cursor ->
        stale_before = DateTime.add(DateTime.utc_now(), -@max_lag_seconds, :second)

        not Repo.exists?(
          from(e in Event,
            where: e.inserted_at > ^cursor.last_inserted_at and e.inserted_at < ^stale_before
          )
        )
    end
  end

  @doc """
  Folds every event inserted since the last run into the rollups, in
  batches. Returns how many new events (past the previous cursor) were
  folded in.
  """
  @spec process_new_events(keyword()) :: non_neg_integer()
  def process_new_events(opts \\ []) do
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)
    max_batches = Keyword.get(opts, :max_batches, @default_max_batches)

    Enum.reduce_while(1..max_batches, 0, fn _batch, total ->
      case process_batch(batch_size) do
        0 -> {:halt, total}
        processed -> {:cont, total + processed}
      end
    end)
  end

  @doc """
  Drops every rollup and the cursor, so the next `process_new_events/1`
  rebuilds everything from raw events - needed after changing a threshold
  that is baked into the stored counters (`panic_debug_gap_seconds`).
  """
  @spec reset() :: :ok
  def reset do
    Repo.transaction(fn ->
      Repo.delete_all(Rollup)
      Repo.delete_all(RollupCursor)
    end)

    DashboardCache.clear()
  end

  defp process_batch(limit) do
    cursor_at =
      case Repo.get(RollupCursor, @cursor) do
        nil -> nil
        cursor -> cursor.last_inserted_at
      end

    # This batch ends at the insertion time of the `limit`-th new event;
    # every event up to and including that second is taken, so a batch
    # never splits one second's events.
    new_times =
      Event
      |> since_cursor(cursor_at)
      |> order_by([e], asc: e.inserted_at)
      |> limit(^limit)
      |> select([e], e.inserted_at)
      |> Repo.all()

    upper = List.last(new_times) || cursor_at
    scan_from = cursor_at && DateTime.add(cursor_at, -@overlap_seconds, :second)

    events =
      if upper do
        Event
        |> where([e], e.inserted_at <= ^upper)
        |> then(fn q -> if scan_from, do: where(q, [e], e.inserted_at > ^scan_from), else: q end)
        |> select([e], %{
          account_id: e.account_id,
          cohort_id: e.cohort_id,
          block_id: e.block_id,
          occurred_at: e.occurred_at,
          inserted_at: e.inserted_at
        })
        |> Repo.all()
      else
        []
      end

    if events != [] do
      Repo.transaction(fn ->
        events |> dirty_buckets() |> Enum.each(&recompute/1)
        save_cursor(upper)
      end)
    end

    Enum.count(events, &(is_nil(cursor_at) or DateTime.compare(&1.inserted_at, cursor_at) == :gt))
  end

  defp since_cursor(query, nil), do: query
  defp since_cursor(query, at), do: where(query, [e], e.inserted_at > ^at)

  # `%{{cohort_id, section_id, day} => [account_id]}` for every bucket the
  # batch touched. Events on deleted blocks have no section and are dropped.
  defp dirty_buckets(events) do
    events = Enum.reject(events, &is_nil(&1.cohort_id))
    section_by_block = section_ids(events |> Enum.map(& &1.block_id) |> Enum.uniq())

    events
    |> Enum.filter(&Map.has_key?(section_by_block, &1.block_id))
    |> Enum.group_by(
      fn event ->
        day = event.occurred_at |> TimeZones.to_app_zone() |> DateTime.to_date()
        {event.cohort_id, Map.fetch!(section_by_block, event.block_id), day}
      end,
      & &1.account_id
    )
    |> Enum.map(fn {key, account_ids} -> {key, Enum.uniq(account_ids)} end)
  end

  defp section_ids([]), do: %{}

  defp section_ids(block_ids) do
    from(b in Block, where: b.id in ^block_ids, select: {b.id, b.section_id})
    |> Repo.all()
    |> Map.new()
  end

  defp recompute({{cohort_id, section_id, day}, account_ids}) do
    positions =
      from(b in Block,
        where: b.section_id == ^section_id,
        select: {b.id, {b.section_id, b.order}}
      )
      |> Repo.all()
      |> Map.new()

    block_ids = Map.keys(positions)
    from_at = TimeZones.start_of_day(day)
    until = day |> Date.add(1) |> TimeZones.start_of_day()

    buckets =
      from(e in Event,
        where:
          e.cohort_id == ^cohort_id and e.account_id in ^account_ids and e.block_id in ^block_ids and
            e.occurred_at >= ^from_at and e.occurred_at < ^until
      )
      |> Repo.all()
      |> Accumulator.build(positions)

    from(r in Rollup,
      where:
        r.cohort_id == ^cohort_id and r.account_id in ^account_ids and r.block_id in ^block_ids and
          r.day == ^day
    )
    |> Repo.delete_all()

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
      for {{account_id, block_id, ^day}, acc} <- buckets do
        acc
        |> Map.take([:hour_counts | Accumulator.fields()])
        |> Map.merge(%{
          id: Ecto.UUID.generate(),
          cohort_id: cohort_id,
          account_id: account_id,
          block_id: block_id,
          day: day,
          updated_at: now
        })
      end

    rows |> Enum.chunk_every(1_000) |> Enum.each(&Repo.insert_all(Rollup, &1))
  end

  defp save_cursor(at) do
    Repo.insert!(
      %RollupCursor{name: @cursor, last_inserted_at: at},
      on_conflict: {:replace, [:last_inserted_at, :updated_at]},
      conflict_target: :name
    )
  end

  # Reading

  @doc """
  Every student's totals per block over `[from_day, to_day]` (either bound
  may be `nil` for "open"), as `%{{account_id, block_id} => accumulator}`.
  `hour_counts` is not summed here - see `hour_matrix/4`.
  """
  @spec account_block_totals(binary(), [binary()], Date.t() | nil, Date.t() | nil) :: map()
  def account_block_totals(cohort_id, block_ids, from_day, to_day) do
    sums = Map.new(Accumulator.fields(), &{&1, dynamic([r], sum(field(r, ^&1)))})

    select =
      Map.merge(sums, %{
        account_id: dynamic([r], r.account_id),
        block_id: dynamic([r], r.block_id)
      })

    cohort_id
    |> window(block_ids, from_day, to_day)
    |> group_by([r], [r.account_id, r.block_id])
    |> select(^select)
    |> Repo.all()
    |> Map.new(fn row ->
      acc =
        Accumulator.empty()
        |> Map.merge(Map.drop(row, [:account_id, :block_id]), fn _key, _zero, value ->
          value || 0
        end)

      {{row.account_id, row.block_id}, acc}
    end)
  end

  @doc "Distinct active students per day: `%{date => count}`."
  @spec active_students_by_day(binary(), [binary()], Date.t() | nil, Date.t() | nil) :: map()
  def active_students_by_day(cohort_id, block_ids, from_day, to_day) do
    cohort_id
    |> window(block_ids, from_day, to_day)
    |> where([r], r.event_count > 0)
    |> group_by([r], r.day)
    |> select([r], {r.day, count(r.account_id, :distinct)})
    |> Repo.all()
    |> Map.new()
  end

  @doc "Event counts per (ISO day of week, hour): `%{{1..7, 0..23} => count}`."
  @spec hour_matrix(binary(), [binary()], Date.t() | nil, Date.t() | nil) :: map()
  def hour_matrix(cohort_id, block_ids, from_day, to_day) do
    cohort_id
    |> window(block_ids, from_day, to_day)
    |> select([r], {r.day, r.hour_counts})
    |> Repo.all()
    |> Enum.reduce(%{}, fn {day, hours}, acc ->
      dow = Date.day_of_week(day)

      hours
      |> Enum.with_index()
      |> Enum.reduce(acc, fn
        {0, _hour}, acc2 -> acc2
        {count, hour}, acc2 -> Map.update(acc2, {dow, hour}, count, &(&1 + count))
      end)
    end)
  end

  defp window(cohort_id, block_ids, from_day, to_day) do
    Rollup
    |> where([r], r.cohort_id == ^cohort_id and r.block_id in ^block_ids)
    |> then(fn q -> if from_day, do: where(q, [r], r.day >= ^from_day), else: q end)
    |> then(fn q -> if to_day, do: where(q, [r], r.day <= ^to_day), else: q end)
  end
end
