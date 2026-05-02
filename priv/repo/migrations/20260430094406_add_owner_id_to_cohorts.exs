defmodule Athena.Repo.Migrations.AddOwnerIdToCohorts do
  use Ecto.Migration

  def up do
    alter table(:cohorts) do
      add :owner_id, :binary_id
    end

    execute """
    UPDATE cohorts
    SET owner_id = COALESCE(
      (SELECT a.id FROM accounts a JOIN roles r ON a.role_id = r.id WHERE r.name = 'admin' LIMIT 1),
      (SELECT id FROM accounts ORDER BY inserted_at ASC LIMIT 1)
    )
    WHERE owner_id IS NULL
    """

    alter table(:cohorts) do
      modify :owner_id, :binary_id, null: false
    end

    create index(:cohorts, [:owner_id])
  end

  def down do
    drop index(:cohorts, [:owner_id])

    alter table(:cohorts) do
      remove :owner_id
    end
  end
end
