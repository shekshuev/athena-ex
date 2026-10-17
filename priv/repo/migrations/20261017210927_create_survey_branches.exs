defmodule Athena.Repo.Migrations.CreateSurveyBranches do
  use Ecto.Migration

  def change do
    create table(:survey_branches, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :survey_id,
          references(:surveys,
            type: :binary_id,
            on_delete: :delete_all,
            name: :survey_branches__survey_id__fk
          ),
          null: false

      # Deleting a question takes its rules with it. Rules that *target* the
      # deleted question are repaired by `Athena.Surveys.Branches`, which is
      # also what reports them through `Flow.validate_graph/1` - a dangling
      # target is a reviewable warning, not a reason to refuse the delete.
      add :question_id,
          references(:survey_questions,
            type: :binary_id,
            on_delete: :delete_all,
            name: :survey_branches__question_id__fk
          ),
          null: false

      add :position, :integer, null: false, default: 0
      add :condition, :map, null: false
      add :action, :string, null: false
      add :target_question_id, :binary_id
      add :target_page, :integer

      timestamps(type: :utc_datetime)
    end

    create index(:survey_branches, [:question_id, :position],
             name: :survey_branches__question_position__idx
           )

    create index(:survey_branches, [:survey_id], name: :survey_branches__survey_id__idx)
  end
end
