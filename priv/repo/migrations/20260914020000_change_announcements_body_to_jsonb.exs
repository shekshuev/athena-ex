defmodule Athena.Repo.Migrations.ChangeAnnouncementsBodyToJsonb do
  use Ecto.Migration

  def change do
    alter table(:announcements) do
      remove :body, :text
      add :body, :map, null: false, default: %{}
    end
  end
end
