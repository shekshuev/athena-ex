defmodule Athena.Repo.Migrations.CreateEngagementEvents do
  use Ecto.Migration

  def change do
    create table(:engagement_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :account_id, :binary_id, null: false
      add :block_id, :binary_id, null: false
      add :section_id, :binary_id, null: false
      add :cohort_id, :binary_id
      add :session_id, :binary_id, null: false
      add :event_type, :string, null: false
      add :payload, :map, default: %{}
      add :occurred_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:engagement_events, [:account_id, :block_id])
    create index(:engagement_events, [:cohort_id, :block_id])
    create index(:engagement_events, [:session_id])
    create index(:engagement_events, [:event_type])
  end
end
