defmodule Athena.Repo.Migrations.AddHeartbeatAtToSubmissions do
  use Ecto.Migration

  # Only an exam attempt uses this: it records when the member sitting it
  # was last seen, so a team's shared attempt can be handed over once its
  # holder goes away instead of locking the rest of the team out until the
  # time limit runs down. Written systemically, never cast from params.
  def change do
    alter table(:submissions) do
      add :heartbeat_at, :utc_datetime
    end
  end
end
