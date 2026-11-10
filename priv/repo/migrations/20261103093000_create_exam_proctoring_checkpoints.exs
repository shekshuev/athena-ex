defmodule Athena.Repo.Migrations.CreateExamProctoringCheckpoints do
  @moduledoc """
  Durable, periodically-refreshed snapshot of one exam attempt's live
  `Athena.Engagement.ProctoringMonitor` state.

  The monitor accumulates integrity signals (away time, silence, paste,
  typing, ...) in memory and only writes them into `Submission.content` at
  `finalize/1`. If the node restarts or the monitor process crashes
  mid-attempt, that in-memory state is lost and the attempt would otherwise
  look clean. This table lets a freshly-started monitor resume from the last
  checkpoint instead of from zero. One row per in-progress attempt, deleted
  when the attempt is finalized.

  `data` is an opaque `:erlang.term_to_binary/1` blob of the monitor's
  serializable state - intentionally not a set of typed columns, so the
  monitor's internal shape can evolve without a migration (a checkpoint that
  no longer deserializes is simply ignored, see `ProctoringCheckpoint.load/1`).
  """
  use Ecto.Migration

  def change do
    create table(:exam_proctoring_checkpoints, primary_key: false) do
      add :submission_id, :binary_id, primary_key: true
      add :data, :binary, null: false

      timestamps(type: :utc_datetime_usec)
    end
  end
end
