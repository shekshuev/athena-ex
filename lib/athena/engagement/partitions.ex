defmodule Athena.Engagement.Partitions do
  @moduledoc """
  Monthly partitions of `engagement_events` (range-partitioned by
  `inserted_at`, the server's clock).

  Raw events are kept indefinitely, so the table only grows; partitions keep
  each month's rows and indexes separate. Queries that bound `inserted_at`
  skip whole months, vacuum and index maintenance work month by month, and
  old months stay out of the way of the current one.

  A month's partition must exist before its first event arrives:
  `ensure/1` (daily, `Athena.Engagement.Workers.EnsurePartitions`) creates
  the current month and the next ones ahead of time. The
  `engagement_events_default` partition catches anything outside every
  monthly range, so a missed run never loses an event; it should stay
  empty.
  """

  require Logger
  alias Athena.Repo

  @parent "engagement_events"

  @doc """
  Creates the partitions for the current month and `months_ahead` months
  after it, skipping those that already exist. Returns the names created.
  """
  @spec ensure(non_neg_integer()) :: [String.t()]
  def ensure(months_ahead \\ 2) do
    first = Date.utc_today() |> Date.beginning_of_month()

    0..months_ahead
    |> Enum.map(&Date.shift(first, month: &1))
    |> Enum.flat_map(&create_month/1)
  end

  @doc "Name of the partition holding the month of `date`."
  @spec name_for(Date.t()) :: String.t()
  def name_for(%Date{year: year, month: month}),
    do: "#{@parent}_p#{year}_#{String.pad_leading(Integer.to_string(month), 2, "0")}"

  @doc """
  The `CREATE TABLE ... PARTITION OF` statement for the month of `date`
  (shared with the migration that partitioned the table).
  """
  @spec create_sql(Date.t()) :: String.t()
  def create_sql(date) do
    from = Date.beginning_of_month(date)
    to = Date.shift(from, month: 1)

    "CREATE TABLE IF NOT EXISTS #{name_for(from)} PARTITION OF #{@parent} " <>
      "FOR VALUES FROM ('#{from} 00:00:00') TO ('#{to} 00:00:00')"
  end

  @legacy "engagement_events_legacy"
  @columns "id, account_id, block_id, section_id, cohort_id, session_id, event_type, " <>
             "payload, occurred_at, inserted_at"

  @doc """
  Moves up to `limit` of the newest rows still in `engagement_events_legacy`
  (the table as it was before partitioning) into `engagement_events`, in
  one statement - a row is either still in the old table or already in the
  new one, never both or neither. Returns how many rows were moved, or
  `:done` once the old table is gone.

  Newest first, so the data the live views read (recent sessions, current
  exams) is back first.
  """
  @spec move_legacy_batch(pos_integer()) :: non_neg_integer() | :done
  def move_legacy_batch(limit) do
    if exists?(@legacy) do
      %{rows: [[moved]]} =
        Repo.query!(
          """
          WITH moved AS (
            DELETE FROM #{@legacy}
            WHERE id IN (SELECT id FROM #{@legacy} ORDER BY inserted_at DESC LIMIT $1)
            RETURNING #{@columns}
          ), inserted AS (
            INSERT INTO #{@parent} (#{@columns})
            SELECT #{@columns} FROM moved
            ON CONFLICT DO NOTHING
          )
          SELECT count(*) FROM moved
          """,
          [limit],
          timeout: :timer.minutes(2)
        )

      moved
    else
      :done
    end
  end

  @doc """
  Drops `engagement_events_legacy` if it exists and is empty (every row
  moved). Returns whether it was dropped.
  """
  @spec drop_empty_legacy() :: boolean()
  def drop_empty_legacy do
    with true <- exists?(@legacy),
         %{rows: []} <- Repo.query!("SELECT 1 FROM #{@legacy} LIMIT 1") do
      Repo.query!("DROP TABLE #{@legacy}")
      Logger.info("[Engagement.Partitions] all legacy events moved, dropped #{@legacy}")
      true
    else
      _ -> false
    end
  end

  defp create_month(date) do
    name = name_for(date)

    if exists?(name) do
      []
    else
      Repo.query!(create_sql(date))
      Logger.info("[Engagement.Partitions] created #{name}")
      [name]
    end
  rescue
    # Rows for this month already sitting in the default partition block
    # the new partition; logged loudly, the events themselves are safe.
    error in Postgrex.Error ->
      Logger.error(
        "[Engagement.Partitions] could not create #{name_for(date)}: #{Exception.message(error)}"
      )

      []
  end

  defp exists?(name) do
    %{rows: [[oid]]} = Repo.query!("SELECT to_regclass($1)::oid", [name])
    not is_nil(oid)
  end
end
