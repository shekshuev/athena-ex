defmodule Athena.Repo.Migrations.CreateAnnouncements do
  use Ecto.Migration

  def change do
    create table(:announcements, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :title, :string, null: false
      add :body, :text, null: false
      add :scope, :string, null: false
      add :cohort_id, :binary_id
      add :author_id, :binary_id, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:announcements, [:scope])
    create index(:announcements, [:cohort_id])
  end
end
