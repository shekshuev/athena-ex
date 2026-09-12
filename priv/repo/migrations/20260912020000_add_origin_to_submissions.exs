defmodule Athena.Repo.Migrations.AddOriginToSubmissions do
  use Ecto.Migration

  def change do
    alter table(:submissions) do
      add :origin, :string, null: false, default: "regular"
    end

    create index(:submissions, [:origin])
  end
end
