defmodule :"Elixir.Athena.Repo.Migrations.Add-deleted-at-to-courses" do
  use Ecto.Migration

  def change do
    alter table(:courses) do
      add :deleted_at, :utc_datetime
    end

    create index(:courses, [:deleted_at])
  end
end
