defmodule Athena.Repo.Migrations.CreateSurveyResponses do
  use Ecto.Migration

  def change do
    create table(:survey_responses, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :survey_id,
          references(:surveys,
            type: :binary_id,
            on_delete: :delete_all,
            name: :survey_responses__survey_id__fk
          ),
          null: false

      # Bare ids, no foreign keys: this context stays loosely coupled to
      # Learning and Identity, the same convention as
      # `Athena.Announcements.Announcement`.
      add :account_id, :binary_id, null: false
      add :cohort_id, :binary_id
      add :course_id, :binary_id
      add :block_id, :binary_id

      add :status, :string, null: false, default: "in_progress"
      add :started_at, :utc_datetime
      add :completed_at, :utc_datetime
      add :last_activity_at, :utc_datetime
      add :current_question_id, :binary_id

      timestamps(type: :utc_datetime)
    end

    # One response per student per survey. Does double duty: it stops a second
    # submission, and it is how an interrupted response is found again on the
    # next page load.
    create unique_index(:survey_responses, [:survey_id, :account_id],
             name: :survey_responses__survey_id__account_id__uk
           )

    # The results axis: every aggregate groups by cohort within a survey.
    create index(:survey_responses, [:survey_id, :cohort_id, :status],
             name: :survey_responses__survey_cohort_status__idx
           )

    # "Has this student answered the survey on this block" for the player.
    create index(:survey_responses, [:block_id, :account_id],
             name: :survey_responses__block_account__idx,
             where: "block_id IS NOT NULL"
           )
  end
end
