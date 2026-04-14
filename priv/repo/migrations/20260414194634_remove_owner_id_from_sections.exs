defmodule Athena.Repo.Migrations.RemoveOwnerIdFromSections do
  use Ecto.Migration

  def change do
    alter table(:sections) do
      remove :owner_id, :binary_id
    end
  end
end
