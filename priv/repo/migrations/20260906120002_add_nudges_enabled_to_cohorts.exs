defmodule Athena.Repo.Migrations.AddNudgesEnabledToCohorts do
  use Ecto.Migration

  def change do
    alter table(:cohorts) do
      add :nudges_enabled, :boolean, null: false, default: false
    end
  end
end
