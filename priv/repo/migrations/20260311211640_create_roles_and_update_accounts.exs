defmodule Athena.Repo.Migrations.CreateRolesAndUpdateAccounts do
  use Ecto.Migration

  def change do
    create table(:roles, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false

      add :permissions, :jsonb, default: "[]", null: false
      add :policies, :jsonb, default: "{}", null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:roles, [:name], name: :roles__name__uk)

    alter table(:accounts) do
      add :role_id,
          references(:roles,
            on_delete: :restrict,
            type: :binary_id,
            name: :accounts__role_id__fk
          ), null: false
    end

    create index(:accounts, [:role_id])
  end
end
