defmodule Athena.Repo.Migrations.CreateSubmissions do
  use Ecto.Migration

  def change do
    create table(:submissions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :account_id, :binary_id, null: false
      add :block_id, :binary_id, null: false

      add :content, :map, default: %{}
      add :status, :string, null: false, default: "pending"
      add :score, :integer, default: 0
      add :feedback, :text

      timestamps(type: :utc_datetime)
    end

    create index(:submissions, [:account_id])
    create index(:submissions, [:block_id])
    create index(:submissions, [:status])
  end
end
