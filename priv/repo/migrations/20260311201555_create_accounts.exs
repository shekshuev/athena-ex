defmodule Athena.Repo.Migrations.CreateAccounts do
  use Ecto.Migration

  def change do
    create table(:accounts, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :login, :string, null: false
      add :password_hash, :string, null: false

      add :status, :string, default: "active", null: false

      add :deleted_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:accounts, [:login], name: :accounts__login__uk)
  end
end
