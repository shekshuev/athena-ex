defmodule Athena.Repo.Migrations.MediaFilesAndQuotas do
  use Ecto.Migration

  def change do
    create table(:media_files, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :bucket, :string, null: false
      add :key, :string, null: false
      add :original_name, :string, null: false
      add :mime_type, :string, null: false
      add :size, :bigint, null: false
      add :context, :string, null: false
      add :owner_id, :binary_id, null: false

      timestamps(type: :utc_datetime)
    end

    create table(:media_quotas, primary_key: false) do
      add :role_id, :binary_id, primary_key: true
      add :limit_bytes, :bigint, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:media_files, [:owner_id])
    create index(:media_files, [:context])
    create unique_index(:media_files, [:bucket, :key])
  end
end
