defmodule Athena.Repo.Migrations.CreateSurveyAnswers do
  use Ecto.Migration

  def change do
    create table(:survey_answers, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :response_id,
          references(:survey_responses,
            type: :binary_id,
            on_delete: :delete_all,
            name: :survey_answers__response_id__fk
          ),
          null: false

      add :question_id,
          references(:survey_questions,
            type: :binary_id,
            on_delete: :delete_all,
            name: :survey_answers__question_id__fk
          ),
          null: false

      # Empty for every type but `:multi_scale`, which writes one row per
      # matrix row. Part of the unique index below, so it cannot be null.
      add :row_key, :string, null: false, default: ""

      add :value, :map, null: false, default: "{}"

      # Projections of `value`, derived in the changeset only (see
      # `Athena.Surveys.SurveyAnswer`). They exist so the statistics are SQL
      # rather than JSON decoding in Elixir.
      add :value_numeric, :float
      add :value_text, :text
      add :value_choice_ids, {:array, :string}, null: false, default: []

      add :skipped, :boolean, null: false, default: false
      add :answered_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    # Also the upsert target for autosave: an answer re-saved as the respondent
    # changes their mind replaces the row instead of adding one.
    create unique_index(:survey_answers, [:response_id, :question_id, :row_key],
             name: :survey_answers__response_id__question_id__row_key__uk
           )

    # Frequencies, descriptives and crosstabs all read a whole question's
    # answers at once; the projections are included so the common aggregates
    # are index-only scans.
    create index(:survey_answers, [:question_id, :row_key],
             name: :survey_answers__question_row__idx,
             include: [:value_numeric, :skipped]
           )

    # Membership counting for choice questions: `value_choice_ids @> ARRAY[id]`.
    execute """
            CREATE INDEX survey_answers__value_choice_ids__gin
            ON survey_answers USING GIN (value_choice_ids)
            """,
            "DROP INDEX survey_answers__value_choice_ids__gin"
  end
end
