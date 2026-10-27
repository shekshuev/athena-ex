defmodule Athena.Repo.Migrations.AddScheduleToCourses do
  use Ecto.Migration

  def change do
    alter table(:courses) do
      add :starts_at, :utc_datetime
      add :ends_at, :utc_datetime
    end

    # The dashboard's upcoming/current/past competition buckets all key off
    # these two columns alongside `type`/`status`, so index the window.
    create index(:courses, [:type, :status, :starts_at, :ends_at])
  end
end
