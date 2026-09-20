defmodule Athena.Repo.Migrations.AddPersonalFileSharing do
  use Ecto.Migration

  def change do
    alter table(:media_files) do
      add :is_public, :boolean, default: false, null: false
    end

    create table(:media_file_shares, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :media_file_id, references(:media_files, on_delete: :delete_all, type: :binary_id),
        null: false

      add :account_id, :uuid, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:media_file_shares, [:media_file_id, :account_id])
  end
end
