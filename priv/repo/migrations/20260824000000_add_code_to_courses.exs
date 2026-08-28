defmodule Athena.Repo.Migrations.AddCodeToCourses do
  use Ecto.Migration

  def change do
    alter table(:courses) do
      add :code, :string
    end

    create unique_index(:courses, [:code], where: "code IS NOT NULL")
  end
end
