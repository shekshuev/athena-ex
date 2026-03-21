defmodule Athena.Repo.Migrations.AddLtreeExtension do
  use Ecto.Migration

  def up do
    execute("CREATE EXTENSION IF NOT EXISTS ltree")
  end

  def down do
    execute("DROP EXTENSION IF EXISTS ltree")
  end
end
