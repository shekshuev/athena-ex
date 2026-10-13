defmodule Athena.Repo.Migrations.PartitionEngagementEvents do
  @moduledoc """
  Turns `engagement_events` into a table range-partitioned by month on
  `inserted_at` (see `Athena.Engagement.Partitions`), without copying any
  data inside the migration:

    1. the existing table is renamed to `engagement_events_legacy` and
       keeps only the two indexes the copy needs;
    2. a new, empty, partitioned `engagement_events` takes its name: one
       partition per month from the oldest event up to two months ahead,
       plus a default partition as a safety net;
    3. new events go to the new table at once; the existing rows are moved
       over in small batches, newest first, by
       `Athena.Engagement.Workers.MoveLegacyEvents`. A later migration
       drops the legacy table once it is empty.

  Rollups are not touched (the rollup cursor only moves forward, and every
  legacy event is already behind it).

  The new indexes cover what reads actually filter on: cohort + block,
  account + block (proctoring, purges), cohort + account (rollup recompute),
  block alone (cohort-less students), all with `occurred_at` last, plus
  `inserted_at` for the rollup cursor. The old `event_type` and
  `session_id` indexes had no reader.
  """
  use Ecto.Migration

  @indexes [
    {"engagement_events__cohort_block_occurred__idx", "(cohort_id, block_id, occurred_at)"},
    {"engagement_events__account_block_occurred__idx", "(account_id, block_id, occurred_at)"},
    {"engagement_events__cohort_account_occurred__idx", "(cohort_id, account_id, occurred_at)"},
    {"engagement_events__block_occurred__idx", "(block_id, occurred_at)"},
    {"engagement_events__inserted_at__idx", "(inserted_at)"}
  ]

  def up do
    # Read before the commands below run (they are queued until the end of
    # `up`), while the table still has its old name.
    months = months_to_create()

    execute "ALTER TABLE engagement_events RENAME TO engagement_events_legacy"
    execute "ALTER INDEX engagement_events_pkey RENAME TO engagement_events_legacy_pkey"

    execute "ALTER INDEX engagement_events_inserted_at_index " <>
              "RENAME TO engagement_events_legacy_inserted_at_index"

    for index <- ~w(engagement_events_account_id_block_id_index
                    engagement_events_cohort_id_block_id_index
                    engagement_events_cohort_id_occurred_at_index
                    engagement_events_event_type_index
                    engagement_events_session_id_index) do
      execute "DROP INDEX IF EXISTS #{index}"
    end

    execute """
    CREATE TABLE engagement_events (
      id uuid NOT NULL,
      account_id uuid NOT NULL,
      block_id uuid NOT NULL,
      section_id uuid NOT NULL,
      cohort_id uuid,
      session_id uuid NOT NULL,
      event_type varchar(255) NOT NULL,
      payload jsonb DEFAULT '{}'::jsonb,
      occurred_at timestamp(0) without time zone NOT NULL,
      inserted_at timestamp(0) without time zone NOT NULL,
      PRIMARY KEY (id, inserted_at)
    ) PARTITION BY RANGE (inserted_at)
    """

    execute "CREATE TABLE engagement_events_default PARTITION OF engagement_events DEFAULT"

    for month <- months do
      execute create_partition_sql(month)
    end

    for {name, columns} <- @indexes do
      execute "CREATE INDEX #{name} ON engagement_events #{columns}"
    end
  end

  def down do
    # The legacy table is dropped once every row has been moved out of it.
    execute """
    CREATE TABLE IF NOT EXISTS engagement_events_legacy (
      id uuid PRIMARY KEY,
      account_id uuid NOT NULL,
      block_id uuid NOT NULL,
      section_id uuid NOT NULL,
      cohort_id uuid,
      session_id uuid NOT NULL,
      event_type varchar(255) NOT NULL,
      payload jsonb DEFAULT '{}'::jsonb,
      occurred_at timestamp(0) without time zone NOT NULL,
      inserted_at timestamp(0) without time zone NOT NULL
    )
    """

    execute """
    CREATE INDEX IF NOT EXISTS engagement_events_legacy_inserted_at_index
    ON engagement_events_legacy (inserted_at)
    """

    execute """
    INSERT INTO engagement_events_legacy
    SELECT id, account_id, block_id, section_id, cohort_id, session_id, event_type,
           payload, occurred_at, inserted_at
    FROM engagement_events
    ON CONFLICT DO NOTHING
    """

    execute "DROP TABLE engagement_events"
    execute "ALTER TABLE engagement_events_legacy RENAME TO engagement_events"
    execute "ALTER INDEX engagement_events_legacy_pkey RENAME TO engagement_events_pkey"

    execute "ALTER INDEX engagement_events_legacy_inserted_at_index " <>
              "RENAME TO engagement_events_inserted_at_index"

    create index(:engagement_events, [:account_id, :block_id])
    create index(:engagement_events, [:cohort_id, :block_id])
    create index(:engagement_events, [:cohort_id, :occurred_at])
    create index(:engagement_events, [:event_type])
    create index(:engagement_events, [:session_id])
  end

  # From the month of the oldest existing event (or the current month) to
  # two months ahead.
  defp months_to_create do
    %{rows: [[oldest]]} = repo().query!("SELECT min(inserted_at) FROM engagement_events")

    current = Date.utc_today() |> Date.beginning_of_month()

    first =
      if oldest, do: oldest |> NaiveDateTime.to_date() |> Date.beginning_of_month(), else: current

    last = Date.shift(current, month: 2)

    first
    |> Stream.iterate(&Date.shift(&1, month: 1))
    |> Enum.take_while(&(Date.compare(&1, last) != :gt))
  end

  defp create_partition_sql(month) do
    name =
      "engagement_events_p#{month.year}_#{String.pad_leading(Integer.to_string(month.month), 2, "0")}"

    next = Date.shift(month, month: 1)

    "CREATE TABLE #{name} PARTITION OF engagement_events " <>
      "FOR VALUES FROM ('#{month} 00:00:00') TO ('#{next} 00:00:00')"
  end
end
