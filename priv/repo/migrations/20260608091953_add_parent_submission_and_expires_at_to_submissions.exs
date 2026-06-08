defmodule Athena.Repo.Migrations.AddParentSubmissionAndExpiresAtToSubmissions do
  use Ecto.Migration

  def change do
    alter table(:submissions) do
      add :parent_submission_id,
          references(:submissions, type: :binary_id, on_delete: :delete_all)

      add :expires_at, :utc_datetime
    end

    create index(:submissions, [:parent_submission_id])

    create index(:submissions, [:expires_at])
  end
end
