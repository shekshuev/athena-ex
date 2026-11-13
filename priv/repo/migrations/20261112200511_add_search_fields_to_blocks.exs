defmodule Athena.Repo.Migrations.AddSearchFieldsToBlocks do
  use Ecto.Migration

  def change do
    alter table(:blocks) do
      add :search_text, :text
      add :search_due_at, :utc_datetime_usec
    end
  end
end
