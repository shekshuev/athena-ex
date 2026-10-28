defmodule Athena.Repo.Migrations.AddPointsToBlocksAndLibraryBlocks do
  use Ecto.Migration

  # What a task is worth. Nullable with no default on purpose: NULL means
  # "unweighted", which is what every existing block is, and each reader
  # supplies its own default for that (100 for a question inside an exam,
  # the competition's `initial` value on a leaderboard). Backfilling a
  # number here would make an explicit choice out of silence.
  def change do
    alter table(:blocks) do
      add :points, :integer
    end

    alter table(:library_blocks) do
      add :points, :integer
    end
  end
end
