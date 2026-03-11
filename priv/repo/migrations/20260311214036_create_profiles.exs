defmodule Athena.Repo.Migrations.CreateProfiles do
  use Ecto.Migration

  def change do
    create table(:profiles, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :owner_id,
          references(:accounts,
            on_delete: :delete_all,
            type: :binary_id,
            name: :profiles__owner_id__fk
          ), null: false

      add :first_name, :string, size: 100, null: false
      add :last_name, :string, size: 100, null: false
      add :patronymic, :string, size: 100
      add :avatar_url, :text
      add :birth_date, :date
      add :metadata, :jsonb, default: "{}", null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:profiles, [:owner_id], name: :profiles__owner_id__uk)
  end
end
