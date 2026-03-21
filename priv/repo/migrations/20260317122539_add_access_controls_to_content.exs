defmodule :"Elixir.Athena.Repo.Migrations.AddAccessControlsToContent" do
  use Ecto.Migration

  def change do
    alter table(:sections) do
      add :visibility, :string, default: "enrolled", null: false
      add :access_rules, :map, default: %{}, null: false
    end

    alter table(:blocks) do
      add :visibility, :string, default: "inherit", null: false
      add :access_rules, :map, default: %{}, null: false
    end
  end
end
