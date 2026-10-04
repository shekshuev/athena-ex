defmodule Athena.Repo.Migrations.AddCohortOccurredAtIndexToEngagementEvents do
  use Ecto.Migration

  # Every engagement dashboard reads a cohort's events inside a time window
  # ("last 7/30 days"); the existing `(cohort_id, block_id)` index can't
  # serve the `occurred_at >= ?` part of that filter.
  def change do
    create index(:engagement_events, [:cohort_id, :occurred_at])
  end
end
