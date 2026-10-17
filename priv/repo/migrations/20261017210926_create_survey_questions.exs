defmodule Athena.Repo.Migrations.CreateSurveyQuestions do
  use Ecto.Migration

  def change do
    create table(:survey_questions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :survey_id,
          references(:surveys,
            type: :binary_id,
            on_delete: :delete_all,
            name: :survey_questions__survey_id__fk
          ),
          null: false

      add :position, :integer, null: false, default: 0
      add :page, :integer, null: false, default: 0
      add :type, :string, null: false
      add :body, :map, null: false
      add :help_text, :string
      add :required, :boolean, null: false, default: false
      add :config, :map, null: false, default: "{}"

      timestamps(type: :utc_datetime)
    end

    # Not unique on (survey_id, position): a drag-reorder rewrites many rows in
    # one transaction and every intermediate state would violate a unique
    # index. `Athena.Surveys.Questions` renumbers gaplessly instead.
    create index(:survey_questions, [:survey_id, :position],
             name: :survey_questions__survey_position__idx
           )
  end
end
