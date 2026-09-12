defmodule Athena.Repo.Migrations.CreateCharacters do
  use Ecto.Migration

  def change do
    create table(:characters, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :color, :string
      add :avatar_file_id, references(:media_files, type: :binary_id, on_delete: :nilify_all)

      add :owner_id, :binary_id, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:characters, [:owner_id])
  end
end
