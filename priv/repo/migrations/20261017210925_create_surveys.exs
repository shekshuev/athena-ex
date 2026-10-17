defmodule Athena.Repo.Migrations.CreateSurveys do
  use Ecto.Migration

  def change do
    create table(:surveys, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :title, :string, null: false
      add :description, :map
      add :status, :string, null: false, default: "draft"
      add :owner_id, :binary_id, null: false
      add :source_survey_id, :binary_id
      add :settings, :map, null: false, default: "{}"
      add :published_at, :utc_datetime
      add :closed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:surveys, [:owner_id], name: :surveys__owner_id__idx)
    create index(:surveys, [:status], name: :surveys__status__idx)

    # "Which versions descend from this survey" for the duplicate-as-version
    # flow; partial because the vast majority of surveys are not copies.
    create index(:surveys, [:source_survey_id],
             name: :surveys__source_survey_id__idx,
             where: "source_survey_id IS NOT NULL"
           )
  end
end
