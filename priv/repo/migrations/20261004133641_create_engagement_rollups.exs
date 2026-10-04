defmodule Athena.Repo.Migrations.CreateEngagementRollups do
  use Ecto.Migration

  # Daily pre-aggregates of `engagement_events`, one row per
  # (cohort, student, block, app-timezone day) - see
  # `Athena.Engagement.Rollups`. Every column is an additive counter or sum,
  # so any window of days is just a `SUM ... GROUP BY`.
  @counts ~w(event_count enter_count interact_count dwell_n tab_hidden window_blur printscreen
             copy_attempt cut_attempt multi_tab play pause seek ended answer_changed run_attempt
             fast_run_gaps attachment_open image_zoom nudge_shown scroll_n paste_n skip_n ttfa_n
             backtracks)a

  @sums ~w(dwell_sum window_sum offtask_sum idle_sum scroll_sum paste_sum skip_sum ttfa_sum)a

  def change do
    create table(:engagement_rollups, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :cohort_id, :binary_id, null: false
      add :account_id, :binary_id, null: false
      add :block_id, :binary_id, null: false
      add :day, :date, null: false

      for field <- @counts, do: add(field, :integer, null: false, default: 0)
      for field <- @sums, do: add(field, :float, null: false, default: 0.0)

      add :hour_counts, {:array, :integer}, null: false, default: fragment("'{}'")

      timestamps(type: :utc_datetime, inserted_at: false)
    end

    create unique_index(:engagement_rollups, [:cohort_id, :account_id, :block_id, :day])
    create index(:engagement_rollups, [:cohort_id, :day])

    # Single-row-per-name watermark: the insertion time up to which the
    # rollup worker has folded events in.
    create table(:engagement_rollup_cursors, primary_key: false) do
      add :name, :string, primary_key: true
      add :last_inserted_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime, inserted_at: false)
    end

    # The worker scans new events in insertion order.
    create index(:engagement_events, [:inserted_at])
  end
end
