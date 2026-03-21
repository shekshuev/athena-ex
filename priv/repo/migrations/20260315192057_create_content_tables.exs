defmodule Athena.Repo.Migrations.CreateContentTables do
  use Ecto.Migration

  def change do
    create table(:courses, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :title, :string, null: false
      add :description, :text
      add :status, :string, null: false, default: "draft"

      add :owner_id, :binary_id, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:courses, [:owner_id])
    create unique_index(:courses, [:title])

    create table(:sections, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :title, :string, null: false
      add :order, :integer, null: false, default: 0
      add :path, :ltree, null: false
      add :course_id, references(:courses, type: :binary_id, on_delete: :delete_all), null: false

      add :parent_id, references(:sections, type: :binary_id, on_delete: :nilify_all)

      add :owner_id, :binary_id, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:sections, [:course_id])
    create index(:sections, [:parent_id])

    create index(:sections, [:path], using: "GIST")
    create index(:sections, [:owner_id])

    create table(:blocks, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :type, :string, null: false
      add :content, :map, null: false, default: %{}
      add :order, :integer, null: false, default: 0

      add :section_id, references(:sections, type: :binary_id, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime)
    end

    create index(:blocks, [:section_id])

    create table(:library_blocks, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :title, :string, null: false
      add :type, :string, null: false
      add :content, :map, null: false, default: %{}

      add :owner_id, :binary_id, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:library_blocks, [:owner_id])
  end
end
