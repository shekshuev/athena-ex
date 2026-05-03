defmodule Athena.Repo.Migrations.AddContentSharing do
  use Ecto.Migration

  def change do
    alter table(:courses) do
      add :is_public, :boolean, default: false, null: false
    end

    alter table(:library_blocks) do
      add :is_public, :boolean, default: false, null: false
    end

    create table(:course_shares, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :course_id, references(:courses, on_delete: :delete_all, type: :binary_id), null: false

      add :account_id, :uuid, null: false
      add :role, :string, default: "reader", null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:course_shares, [:course_id, :account_id])

    create table(:library_block_shares, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :library_block_id,
          references(:library_blocks, on_delete: :delete_all, type: :binary_id), null: false

      add :account_id, :uuid, null: false
      add :role, :string, default: "reader", null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:library_block_shares, [:library_block_id, :account_id])
  end
end
