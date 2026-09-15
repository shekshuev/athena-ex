defmodule Athena.Repo.Migrations.AddVisibilityWindowAndImportantToAnnouncements do
  use Ecto.Migration

  def change do
    alter table(:announcements) do
      add :important, :boolean, null: false, default: false
      add :starts_at, :utc_datetime
      add :ends_at, :utc_datetime
    end
  end
end
