defmodule Athena.Repo.Migrations.CreateEngagementPurges do
  @moduledoc """
  Requests to delete one student's or one cohort's raw engagement events
  while keeping the aggregates computed from them (see
  `Athena.Engagement.Purges`). A row also tells the rollup worker which
  (student|cohort, day) aggregates may no longer be recomputed, since the
  raw events behind them are gone.
  """
  use Ecto.Migration

  def change do
    create table(:engagement_purges, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :scope, :string, null: false
      add :scope_id, :binary_id, null: false
      add :purged_through, :utc_datetime, null: false
      add :requested_by, :binary_id
      add :status, :string, null: false, default: "pending"
      add :deleted_count, :bigint, null: false, default: 0
      add :completed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:engagement_purges, [:scope, :scope_id])
  end
end
